import { afterEach, describe, expect, test } from "bun:test";
import { createApp } from "./app";

afterEach(() => {
  delete process.env.NODE_ENV;
});

describe("server app", () => {
  test("exposes unauthenticated health endpoint", async () => {
    const app = createApp();
    const response = await app.request("/health");

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });

  test("returns safe responses and redacted logs for unhandled errors", async () => {
    process.env.NODE_ENV = "test";
    const logEntries: unknown[] = [];
    const app = createApp({
      logger: {
        info() {},
        error(_message, metadata) {
          logEntries.push(metadata);
        },
      },
    });

    const response = await app.request("/__test/error", {
      headers: { authorization: "Bearer client-secret-token" },
    });

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "Internal server error" });
    expect(JSON.stringify(logEntries)).not.toContain("client-secret-token");
    expect(JSON.stringify(logEntries)).not.toContain("test secret token should not reach clients");
  });
});
