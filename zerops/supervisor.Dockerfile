# Same image as deployment/computers/supervisor.Dockerfile, but built from a plain
# context prepared in the Zerops build phase (no BuildKit named contexts needed).
FROM oven/bun:1.3.14-alpine
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile
COPY src ./src
COPY LICENSE.openbot ./LICENSE.openbot
EXPOSE 4300
CMD ["bun", "src/index.ts"]
