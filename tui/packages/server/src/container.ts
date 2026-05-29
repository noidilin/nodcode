import "dotenv/config";

import { startServer } from "./index";
import { RuntimeConfigError } from "./config";
import { logger } from "./logger";

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
