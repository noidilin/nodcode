import "dotenv/config";

import { createApp } from "./app";
import { initializeRuntimeConfig, RuntimeConfigError } from "./config";
import { logger } from "./logger";

export { createApp } from "./app";
export type { AppType } from "./app";

export function startServer() {
  const config = initializeRuntimeConfig();
  const app = createApp();

  // idleTimeout must be high, otherwise LLM tool calls might not complete.
  const server = Bun.serve({
    hostname: config.HOST,
    port: config.PORT,
    fetch: app.fetch,
    idleTimeout: 255,
  });

  logger.info("NodCode API server started", {
    host: config.HOST,
    port: server.port,
    environment: config.NODE_ENV,
  });

  let shuttingDown = false;
  const shutdown = async (signal: NodeJS.Signals) => {
    if (shuttingDown) return;
    shuttingDown = true;

    logger.info("NodCode API server shutting down", { signal });
    await server.stop(false);
    logger.info("NodCode API server stopped", { signal });
    process.exit(0);
  };

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);

  return server;
}

if (import.meta.main) {
  try {
    startServer();
  } catch (error) {
    if (error instanceof RuntimeConfigError) {
      logger.error("Server startup failed due to invalid runtime configuration", {
        issues: error.issues,
      });
    } else {
      logger.error("Server startup failed", { error });
    }

    process.exit(1);
  }
}

const app = createApp();
export default app;
