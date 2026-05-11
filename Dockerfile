FROM oven/bun:latest
WORKDIR /app
COPY server.ts .
RUN mkdir -p data public
EXPOSE 8880
CMD ["bun", "run", "server.ts"]
