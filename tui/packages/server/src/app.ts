import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";

import { requireAuth } from "./middleware/require-auth";
import sessions from "./routes/sessions";
import chat from "./routes/chat";
import auth from "./routes/auth";
import billing from "./routes/billing";
import { logger, sanitizeForLog, type Logger } from "./logger";

export type AppDependencies = {
  logger?: Logger;
};

export function createApp(dependencies: AppDependencies = {}) {
  const log = dependencies.logger ?? logger;
  const app = new Hono();

  app.onError((error, c) => {
    if (error instanceof HTTPException) {
      return c.json({ error: error.message || "Request failed" }, error.status);
    }

    log.error("Unhandled server error", sanitizeForLog({
      error,
      request: {
        method: c.req.method,
        path: new URL(c.req.url).pathname,
      },
    }) as Record<string, unknown>);

    return c.json({ error: "Internal server error" }, 500);
  });

  app.get("/health", (c) => c.json({ status: "ok" }));

  if (process.env.NODE_ENV === "test") {
    app.get("/__test/error", () => {
      throw new Error("test secret token should not reach clients");
    });
  }

  app.use("/sessions/*", requireAuth);
  app.use("/chat/*", requireAuth);
  app.use("/billing/checkout", requireAuth);
  app.use("/billing/portal", requireAuth);

  const routes = app
    .route("/auth", auth)
    .route("/billing", billing)
    .route("/sessions", sessions)
    .route("/chat", chat);

  return routes;
}

export type AppType = ReturnType<typeof createApp>;
