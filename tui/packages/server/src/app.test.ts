import { afterEach, describe, expect, test } from "bun:test";
import { createApp, type AppDependencies } from "./app";
import { resetRuntimeConfigForTests } from "./config";

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

function createSessionLifecycleApp(
  creditsByUser: Record<string, number> = {},
  appDependencies: Omit<AppDependencies, "database" | "authenticateRequest" | "getCreditsBalance"> = {},
) {
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
      async findUnique({ where }: { where: { id: string; userId: string } }) {
        return sessions.find(
          (session) => session.id === where.id && session.userId === where.userId,
        ) ?? null;
      },
      async update({ where, data }: { where: { id: string; userId: string }; data: { messages: unknown[] } }) {
        const session = sessions.find(
          (item) => item.id === where.id && item.userId === where.userId,
        );
        if (!session) throw new Error("Session not found");
        session.messages = data.messages;
        return session;
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
    ...appDependencies,
  });

  return { app, sessions, creditChecks };
}

const runtimeEnvKeys = [
  "NODE_ENV",
  "DATABASE_URL",
  "CLERK_SECRET_KEY",
  "CLERK_PUBLISHABLE_KEY",
  "POLAR_ACCESS_TOKEN",
  "POLAR_PRODUCT_ID",
  "POLAR_CREDITS_METER_ID",
  "POLAR_SERVER",
  "BEDROCK_AWS_REGION",
  "BEDROCK_CHAT_MODEL_ID",
];

function configureDeepSeekBedrockRuntime() {
  Object.assign(process.env, {
    NODE_ENV: "test",
    DATABASE_URL: "postgres://user:pass@localhost:5432/nodcode",
    CLERK_SECRET_KEY: "sk_test_secret-value",
    CLERK_PUBLISHABLE_KEY: "pk_test_public-value",
    POLAR_ACCESS_TOKEN: "polar-secret-value",
    POLAR_PRODUCT_ID: "product_123",
    POLAR_CREDITS_METER_ID: "meter_123",
    POLAR_SERVER: "sandbox",
    BEDROCK_AWS_REGION: "ap-northeast-1",
    BEDROCK_CHAT_MODEL_ID: "deepseek.v3.2",
  });
  resetRuntimeConfigForTests();
}

afterEach(() => {
  for (const key of runtimeEnvKeys) {
    delete process.env[key];
  }
  resetRuntimeConfigForTests();
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

  test("rejects unauthenticated chat requests", async () => {
    const { app } = createSessionLifecycleApp({ alice: 10 });

    const response = await app.request("/chat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Unauthorized. Run /login to continue." });
  });

  test("preserves the Polar credit gate for chat requests", async () => {
    const { app, creditChecks } = createSessionLifecycleApp({ alice: 0 });

    const response = await app.request("/chat", {
      method: "POST",
      headers: { authorization: "Bearer user:alice", "content-type": "application/json" },
      body: JSON.stringify({}),
    });

    expect(response.status).toBe(402);
    expect(await response.json()).toEqual({
      error: "No credits remaining. Run /upgrade to buy more credits.",
    });
    expect(creditChecks).toEqual(["alice"]);
  });

  test("validates chat request bodies", async () => {
    const { app } = createSessionLifecycleApp({ alice: 10 });

    const response = await app.request("/chat", {
      method: "POST",
      headers: { authorization: "Bearer user:alice", "content-type": "application/json" },
      body: JSON.stringify({ id: "session-1", messages: [], mode: "BUILD", model: "missing" }),
    });

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "Invalid request body" });
  });

  test("returns 404 for chat requests against missing sessions", async () => {
    const { app } = createSessionLifecycleApp({ alice: 10 });

    const response = await app.request("/chat", {
      method: "POST",
      headers: { authorization: "Bearer user:alice", "content-type": "application/json" },
      body: JSON.stringify({
        id: "missing-session",
        mode: "BUILD",
        model: "bedrock-deepseek-v3-2",
        messages: [{ id: "message-1", role: "user", parts: [{ type: "text", text: "hello" }] }],
      }),
    });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "Session not found" });
  });

  test("streams a mocked DeepSeek Bedrock chat, persists completion, and ingests Polar usage", async () => {
    configureDeepSeekBedrockRuntime();
    const ingestedUsage: unknown[] = [];
    const assistantMessage = {
      id: "assistant-message-1",
      role: "assistant",
      parts: [{ type: "text", text: "Mocked Bedrock response" }],
    };
    const streamText = ((params: any) => ({
      async toUIMessageStreamResponse(options: any) {
        await params.onFinish?.({
          totalUsage: {
            inputTokens: 1_000,
            outputTokens: 2_000,
            totalTokens: 3_000,
          },
          providerMetadata: {
            bedrock: {
              serviceTier: "standard",
            },
          },
        });

        const startMetadata = options.messageMetadata({ part: { type: "start" } });
        const finishMetadata = options.messageMetadata({ part: { type: "finish" } });
        const responseMessage = {
          ...assistantMessage,
          metadata: finishMetadata,
        };

        await options.onFinish({
          isAborted: false,
          responseMessage,
          messages: [
            {
              id: "user-message-1",
              role: "user",
              parts: [{ type: "text", text: "hello" }],
              metadata: startMetadata,
            },
            responseMessage,
          ],
        });

        return new Response("mock stream", {
          headers: { "content-type": "text/plain" },
        });
      },
    })) as AppDependencies["streamText"];

    const { app, sessions, creditChecks } = createSessionLifecycleApp(
      { alice: 10 },
      {
        streamText,
        async ingestAiUsage(event) {
          ingestedUsage.push(event);
        },
      },
    );
    const headers = {
      authorization: "Bearer user:alice",
      "content-type": "application/json",
    };

    await app.request("/sessions", {
      method: "POST",
      headers,
      body: JSON.stringify({ title: "Mocked Bedrock chat" }),
    });

    const response = await app.request("/chat", {
      method: "POST",
      headers,
      body: JSON.stringify({
        id: "session-1",
        mode: "BUILD",
        model: "bedrock-deepseek-v3-2",
        messages: [
          { id: "user-message-1", role: "user", parts: [{ type: "text", text: "hello" }] },
        ],
      }),
    });

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("mock stream");
    expect(creditChecks).toEqual(["alice", "alice"]);
    expect(sessions[0].messages).toHaveLength(2);
    expect(sessions[0].messages[1]).toMatchObject({
      id: "assistant-message-1",
      role: "assistant",
      metadata: {
        provider: "bedrock",
        model: "bedrock-deepseek-v3-2",
        providerModelId: "deepseek.v3.2",
        region: "ap-northeast-1",
        usage: {
          inputTokens: 1_000,
          outputTokens: 2_000,
          totalTokens: 3_000,
        },
        providerMetadata: {
          bedrock: {
            serviceTier: "standard",
          },
        },
      },
    });
    expect(ingestedUsage).toEqual([
      {
        externalCustomerId: "alice",
        eventId: "chat-message:assistant-message-1",
        credits: 2,
      },
    ]);
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
