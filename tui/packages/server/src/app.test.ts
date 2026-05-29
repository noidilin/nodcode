import { afterEach, describe, expect, test } from "bun:test";
import { createApp } from "./app";

type StoredSession = {
  id: string;
  userId: string;
  title: string;
  createdAt: Date;
  updatedAt: Date;
  messages: unknown[];
};

function encodeState(payload: unknown) {
  return Buffer.from(JSON.stringify(payload)).toString("base64url");
}

function createSessionLifecycleApp(creditsByUser: Record<string, number> = {}) {
  const sessions: StoredSession[] = [];
  let nextId = 1;
  const creditChecks: string[] = [];

  const database = {
    session: {
      async findMany({ where }: { where: { userId: string } }) {
        return sessions
          .filter((session) => session.userId === where.userId)
          .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())
          .map(({ id, title, createdAt }) => ({ id, title, createdAt }));
      },
      async findFirst({ where }: { where: { id: string; userId: string } }) {
        return sessions.find(
          (session) => session.id === where.id && session.userId === where.userId,
        ) ?? null;
      },
      async create({ data }: { data: { title: string; userId: string } }) {
        const now = new Date(`2026-01-01T00:00:0${nextId}.000Z`);
        const session = {
          id: `session-${nextId++}`,
          userId: data.userId,
          title: data.title,
          createdAt: now,
          updatedAt: now,
          messages: [],
        };
        sessions.push(session);
        return session;
      },
    },
  };

  const app = createApp({
    database,
    async authenticateRequest(request) {
      const authorization = request.headers.get("authorization");
      if (!authorization?.startsWith("Bearer user:")) {
        return null;
      }

      return { userId: authorization.slice("Bearer user:".length) };
    },
    async getCreditsBalance(userId) {
      creditChecks.push(userId);
      return creditsByUser[userId] ?? 0;
    },
  });

  return { app, sessions, creditChecks };
}

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

  test("forwards Clerk OAuth callback results to the local CLI listener", async () => {
    const app = createApp();
    const state = encodeState({ port: 43210, nonce: "nonce-1" });
    const response = await app.request(
      `/auth/callback?code=oauth-code&state=${encodeURIComponent(state)}`,
      { redirect: "manual" },
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      `http://localhost:43210/callback?code=oauth-code&state=${encodeURIComponent(state)}`,
    );
  });

  test("rejects unauthenticated session requests", async () => {
    const { app } = createSessionLifecycleApp({ "alice": 10 });

    const response = await app.request("/sessions");

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Unauthorized. Run /login to continue." });
  });

  test("creates, lists, and loads authenticated user sessions", async () => {
    const { app, creditChecks } = createSessionLifecycleApp({ "alice": 10 });
    const headers = {
      authorization: "Bearer user:alice",
      "content-type": "application/json",
    };

    const createResponse = await app.request("/sessions", {
      method: "POST",
      headers,
      body: JSON.stringify({ title: "Plan AWS migration" }),
    });
    const created = await createResponse.json();

    expect(createResponse.status).toBe(201);
    expect(created).toMatchObject({
      id: "session-1",
      userId: "alice",
      title: "Plan AWS migration",
      messages: [],
    });
    expect(creditChecks).toEqual(["alice"]);

    const listResponse = await app.request("/sessions", { headers });
    expect(listResponse.status).toBe(200);
    expect(await listResponse.json()).toEqual([
      {
        id: "session-1",
        title: "Plan AWS migration",
        createdAt: "2026-01-01T00:00:01.000Z",
      },
    ]);

    const loadResponse = await app.request("/sessions/session-1", { headers });
    expect(loadResponse.status).toBe(200);
    expect(await loadResponse.json()).toMatchObject({
      id: "session-1",
      userId: "alice",
      title: "Plan AWS migration",
    });
  });

  test("isolates sessions by authenticated owner", async () => {
    const { app } = createSessionLifecycleApp({ alice: 10, bob: 10 });

    await app.request("/sessions", {
      method: "POST",
      headers: { authorization: "Bearer user:alice", "content-type": "application/json" },
      body: JSON.stringify({ title: "Alice session" }),
    });
    await app.request("/sessions", {
      method: "POST",
      headers: { authorization: "Bearer user:bob", "content-type": "application/json" },
      body: JSON.stringify({ title: "Bob session" }),
    });

    const listResponse = await app.request("/sessions", {
      headers: { authorization: "Bearer user:alice" },
    });
    expect(await listResponse.json()).toEqual([
      { id: "session-1", title: "Alice session", createdAt: "2026-01-01T00:00:01.000Z" },
    ]);

    const crossOwnerLoad = await app.request("/sessions/session-2", {
      headers: { authorization: "Bearer user:alice" },
    });
    expect(crossOwnerLoad.status).toBe(404);
  });

  test("preserves the Polar credit gate for session creation", async () => {
    const { app, sessions, creditChecks } = createSessionLifecycleApp({ alice: 0 });

    const response = await app.request("/sessions", {
      method: "POST",
      headers: { authorization: "Bearer user:alice", "content-type": "application/json" },
      body: JSON.stringify({ title: "Should not start" }),
    });

    expect(response.status).toBe(402);
    expect(await response.json()).toEqual({
      error: "No credits remaining. Run /upgrade to buy more credits.",
    });
    expect(sessions).toHaveLength(0);
    expect(creditChecks).toEqual(["alice"]);
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
