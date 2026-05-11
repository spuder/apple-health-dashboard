# INSTALL.md — AI-assisted deployment guide

> **For Claude / GPT / Gemini / Cursor / any AI coding assistant**: this file is written specifically for you to read and execute. Walk the user through it step-by-step. Verify each step before moving on. The user may not know docker — explain what you're doing in plain English when prompted.

---

## What you're deploying

A self-hosted dashboard that ingests Apple Health data from the **Health Auto Export** iOS app and serves a web UI on port 8880. Single-container Bun + SQLite stack. ~140 MB image, <50 MB RAM at rest.

## Prerequisites checklist (verify ALL before continuing)

```bash
# 1. Docker installed and running
docker --version          # need 20.10+
docker compose version     # need v2 (NOT docker-compose v1)

# 2. Network reachability — the iPhone must be able to POST to the host
#    Find the host's LAN IP (the one the iPhone can reach):
ip -4 addr show | grep -oE 'inet [0-9.]+' | grep -v '127\.'
#    On macOS:  ipconfig getifaddr en0

# 3. Port 8880 is free OR pick a different host port
ss -tln | grep 8880     # should print nothing
#    If something is on 8880, edit docker-compose.yml port mapping later

# 4. ~200 MB free disk for image + initial DB growth
df -h .

# 5. Git installed (for cloning)
git --version
```

If any of the above fail, **stop and fix it before continuing**. Don't try to "make it work" with workarounds — the user should have a clean base.

## Step 1 — Clone

```bash
cd ~        # or wherever the user wants the repo
git clone https://github.com/<USERNAME>/apple-health-dashboard.git
cd apple-health-dashboard
```

Replace `<USERNAME>` with the actual GitHub username/org. The user knows this.

## Step 2 — Configure docker-compose.yml

```bash
cp docker-compose.example.yml docker-compose.yml
```

Open `docker-compose.yml` and decide:

- **Direct port exposure (simplest)**: leave `ports: ["8880:8880"]`. The dashboard will be at `http://<host-ip>:8880`.
- **Different host port**: change to `"9090:8880"` (or whatever).
- **Reverse proxy with HTTPS**: uncomment the Traefik labels block, set `Host(\`health.example.com\`)` to a domain you control, ensure your Traefik instance and DNS are configured. The user should already have Traefik working if they're choosing this path — if they don't, default to direct port exposure.

## Step 3 — Build and start

```bash
docker compose up -d --build
```

Expected output: `Container apple-health-dashboard Started`. Wait ~10 seconds, then verify:

```bash
curl -sf http://localhost:8880/health
# expected: {"status":"ok","uptime":...}

curl -s http://localhost:8880/api/stats
# expected on a fresh install: {"metrics":0,"hr_readings":0,"workouts":0,"sleep":0,...}
```

Check container logs:

```bash
docker logs apple-health-dashboard --tail 5
# expected:
#   🏥 Health server running on http://localhost:8880
#   📊 SQLite database: /app/data/health.db
```

If you see anything else, capture the full log (`docker logs apple-health-dashboard`) and stop. Most failures here are port conflicts or volume permission issues.

## Step 4 — Configure Health Auto Export on the iPhone

The user needs to do this part on their phone — guide them.

1. **Buy and install** [Health Auto Export](https://apps.apple.com/us/app/health-auto-export-json-csv/id1115567069) from the App Store ($4.99 one-time).

2. **Open HAE → grant Apple Health permissions**. Allow ALL categories — the app needs broad access to export everything.

3. **Create automation #1: "Workouts"**
   - Type: REST API
   - URL: `http://<host-lan-ip>:8880/health` (the IP you found in prereq #2)
   - Data Type: **Workouts**
   - Include Route Data: **ON**
   - Include Workout Metrics: **ON**
   - Format: JSON v2
   - Date Range: Since Last Sync
   - Schedule: Every **5 minutes**

4. **Create automation #2: "Health Metrics"**
   - Type: REST API
   - URL: same as above
   - Data Type: **Health Metrics**
   - Select Health Metrics: **All**
   - Summarize Data: ON
   - Batch Requests: ON
   - Format: JSON v2
   - Date Range: Since Last Sync
   - Schedule: Every **1 hour**

5. **Tap "Run Now"** on each automation to seed the database.

## Step 5 — Verify data is flowing

```bash
# After ~30 seconds:
curl -s http://localhost:8880/api/stats
# expected: row counts > 0 across metrics, hr_readings, workouts, sleep

docker logs apple-health-dashboard --tail 5
# expected lines like:
#   [2026-05-10T23:15:00.000Z] Ingested health data: 84233 bytes
```

If row counts are still 0 after several "Run Now" taps:
- **Network**: from the iPhone, in Safari, visit `http://<host-lan-ip>:8880/health` — should return JSON. If not, the iPhone can't reach the host (firewall, wrong IP, etc.).
- **Logs**: `docker logs apple-health-dashboard --tail 30` — look for errors like "attempt to write a readonly database" (file permissions on `data/` dir) or "Payload too large" (rare; HAE can push >25 MB on initial sync — bump `MAX_POST_BYTES` in `server.ts` if needed).

## Step 6 — Visit the dashboard

Open a browser to `http://<host-lan-ip>:8880`. Click each tab — Briefing, Today, Trends, Workouts, Sleep, Report, Calendar — and confirm data renders.

The first few hours of data will be sparse. After a full day of HAE syncs, the briefing will populate (recovery score needs at least a few days of baseline). After a week, the 30-day trends and rolling charts come alive.

## Common follow-ups

### Add HTTPS via Traefik

If the user runs Traefik with a wildcard cert:

1. Uncomment the Traefik labels in `docker-compose.yml`
2. Replace `health.example.com` with an actual domain whose DNS points at the Traefik host
3. Set `traefik.tls.certresolver` to whatever resolver name they configured (commonly `letsencrypt`, `cloudflare`, etc.)
4. Add the container to the Traefik external network (uncomment `networks:` block)
5. `docker compose up -d` to apply

### Migrating existing data

If the user already has months of Apple Health data, HAE's "Date Range: All" mode on a one-time export will push it all in one go. Bump `MAX_POST_BYTES` in `server.ts` from 25 MB to 200 MB temporarily, rebuild, then revert after the import.

### Backups

```bash
# data/health.db is the only thing you need to back up
tar czf health-backup-$(date +%F).tar.gz data/
```

For automated backups, add a systemd timer or cron job that does the above and uploads to S3 / B2 / wherever. The container itself doesn't manage backups.

### Updating

```bash
cd apple-health-dashboard
git pull
docker compose up -d --build
```

The container is recreated; the bind-mounted `data/` and `public/` survive untouched.

### Resetting the database (start fresh)

```bash
docker compose down
rm data/health.db data/raw-payloads.jsonl
docker compose up -d --build
# HAE's next push will populate the new DB
```

## Troubleshooting matrix

| Symptom | Cause | Fix |
|---------|-------|-----|
| `curl localhost:8880/health` fails | Container didn't start | `docker logs apple-health-dashboard` — usually a port conflict or volume perm |
| Container starts but `/api/stats` shows zeros after HAE pushes | Phone can't reach host, OR iPhone-host network mismatch | From phone, visit `http://<host-ip>:8880/health` in Safari; if it loads, HAE just hasn't run yet |
| Logs show "attempt to write a readonly database" | Docker volume perms broken | `chmod -R 666 data/` then `docker restart apple-health-dashboard` |
| Sleep shows fragments instead of full nights | HAE didn't export the early-evening "before bed" sleep | Trigger a manual "Run Now" on the Health Metrics automation |
| 5/10 says 4h, iPhone says 10h | Day with multiple sleep events (overnight + naps) | This dashboard already sums them — confirmed against iPhone Health Sleep overview |
| Sleep duration off by 1-2 minutes | Rounding (we round to 0.01h, iPhone rounds to whole minutes) | Working as intended |

## File map (for AI assistants making changes)

```
apple-health-dashboard/
├── server.ts                      # all backend logic — ingest, SQLite, API routes, graceful shutdown
├── public/index.html              # the entire dashboard — inline CSS, inline JS, no build step
├── Dockerfile                     # bun:latest, COPY server.ts, expose 8880
├── docker-compose.example.yml     # users copy this to docker-compose.yml and customize
├── .gitignore                     # prevents data/ from being committed
├── data/.gitkeep                  # placeholder; SQLite + JSONL go here at runtime
├── docs/screenshots/              # PNG screenshots embedded in README
├── README.md                      # human-facing
└── INSTALL.md                     # this file (AI-facing)
```

The two files you'll actually edit are `server.ts` and `public/index.html`. Everything else is config.

## When in doubt

- Re-read the README's architecture diagram. The flow is always: iPhone HAE → POST `/health` → SQLite → GET `/api/*` → browser.
- Every new endpoint goes in `server.ts` near the bottom (`if (url.pathname === "/api/...")`).
- Every new chart goes in `public/index.html` — find a `render*()` pattern that matches your need.
- The `aggregateSleepForDate(day)` helper is the single source of truth for per-day sleep totals. Don't bypass it; HAE's data is messier than you'd think.
