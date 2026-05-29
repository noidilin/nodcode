# syntax=docker/dockerfile:1

FROM oven/bun:1.3.14-slim AS build
WORKDIR /app

# Install workspace dependencies from the monorepo context. Ignore lifecycle scripts so
# Prisma generation can run with an explicit build-time DATABASE_URL placeholder.
COPY . .
RUN bun install --frozen-lockfile --ignore-scripts
RUN DATABASE_URL=postgresql://nodcode:nodcode@localhost:5432/nodcode \
  bun run --cwd packages/database db:generate
RUN bun run --filter @nodcode/server build:container

FROM oven/bun:1.3.14-slim AS runtime
WORKDIR /app

ENV NODE_ENV=production \
  HOST=0.0.0.0 \
  PORT=3000

COPY --from=build --chown=bun:bun /app/packages/server/dist ./packages/server/dist

USER bun
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["bun", "-e", "const port = process.env.PORT || '3000'; const host = process.env.HOST && process.env.HOST !== '0.0.0.0' ? process.env.HOST : '127.0.0.1'; const response = await fetch(`http://${host}:${port}/health`); if (!response.ok) process.exit(1);"]

CMD ["bun", "packages/server/dist/container.js"]
