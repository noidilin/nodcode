import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";

import { createRequireAuth, type AuthenticateRequest } from "./middleware/require-auth";
import { createSessionsRoutes } from "./routes/sessions";
import { createChatRoutes, type ChatStreamText, type IngestAiUsage } from "./routes/chat";
import auth from "./routes/auth";
import billing from "./routes/billing";
import { logger, sanitizeForLog, type Logger } from "./logger";
import type { GetCreditsBalance } from "./middleware/require-credits-balance";

export type AppDependencies = {
  logger?: Logger;
  authenticateRequest?: AuthenticateRequest;
  database?: any;
  getCreditsBalance?: GetCreditsBalance;
  streamText?: ChatStreamText;
  ingestAiUsage?: IngestAiUsage;
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

  const requireAuth = createRequireAuth(dependencies.authenticateRequest);
  const sessions = createSessionsRoutes({
    database: dependencies.database,
    getCreditsBalance: dependencies.getCreditsBalance,
  });
  const chat = createChatRoutes({
    database: dependencies.database,
    getCreditsBalance: dependencies.getCreditsBalance,
    streamText: dependencies.streamText,
    ingestAiUsage: dependencies.ingestAiUsage,
  });

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
