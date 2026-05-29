import { createApp } from "../src/app";

type Mode = "coverage" | "auth" | "effect";
type Method = "GET" | "POST";

type StoredSession = {
  id: string;
  userId: string;
  title: string;
  createdAt: Date;
  updatedAt: Date;
  messages: unknown[];
};

type Scenario = {
  name: string;
  method: Method;
  path: string;
  protected: boolean;
  body?: unknown;
  expectStatus: number;
};

const scenarios: Scenario[] = [
  { name: "health", method: "GET", path: "/health", protected: false, expectStatus: 200 },
  { name: "sessions.list", method: "GET", path: "/sessions", protected: true, expectStatus: 200 },
  {
    name: "sessions.create",
    method: "POST",
    path: "/sessions",
    protected: true,
    body: { title: "HTTP exerciser" },
    expectStatus: 201,
  },
  {
    name: "chat.invalid-body",
    method: "POST",
    path: "/chat",
    protected: true,
    body: { id: "session-1", messages: [], mode: "BUILD", model: "missing" },
    expectStatus: 400,
  },
  {
    name: "chat.missing-session",
    method: "POST",
    path: "/chat",
    protected: true,
    body: {
      id: "missing-session",
      mode: "BUILD",
      model: "bedrock-deepseek-v3-2",
      messages: [{ id: "message-1", role: "user", parts: [{ type: "text", text: "hello" }] }],
    },
    expectStatus: 404,
  },
];

function parseArgs() {
  const args = new Set(process.argv.slice(2));
  const modeArg = process.argv.find((arg) => arg.startsWith("--mode="));
  const mode = (modeArg?.slice("--mode=".length) ?? "effect") as Mode;

  if (!["coverage", "auth", "effect"].includes(mode)) {
    throw new Error(`Unknown mode: ${mode}`);
  }

  return {
    mode,
    failOnMissing: args.has("--fail-on-missing"),
    failOnSkip: args.has("--fail-on-skip"),
  };
}

function createExerciseApp(creditsByUser: Record<string, number> = { alice: 10 }) {
  const sessions: StoredSession[] = [
    {
      id: "session-1",
      userId: "alice",
      title: "Seeded session",
      createdAt: new Date("2026-01-01T00:00:00.000Z"),
      updatedAt: new Date("2026-01-01T00:00:00.000Z"),
      messages: [],
    },
  ];
  let nextId = 2;

  const database = {
    session: {
      async findMany({ where }: { where: { userId: string } }) {
        return sessions
          .filter((session) => session.userId === where.userId)
          .map(({ id, title, createdAt }) => ({ id, title, createdAt }));
      },
      async findFirst({ where }: { where: { id: string; userId: string } }) {
        return sessions.find((session) => session.id === where.id && session.userId === where.userId) ?? null;
      },
      async findUnique({ where }: { where: { id: string; userId: string } }) {
        return sessions.find((session) => session.id === where.id && session.userId === where.userId) ?? null;
      },
      async update({ where, data }: { where: { id: string; userId: string }; data: { messages: unknown[] } }) {
        const session = sessions.find((item) => item.id === where.id && item.userId === where.userId);
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

  return createApp({
    database,
    async authenticateRequest(request) {
      const authorization = request.headers.get("authorization");
      if (authorization !== "Bearer exerciser") return null;
      return { userId: "alice" };
    },
    async getCreditsBalance(userId) {
      return creditsByUser[userId] ?? 0;
    },
  });
}

async function call(scenario: Scenario, authenticated = true) {
  const app = createExerciseApp();
  const headers: Record<string, string> = {};
  if (authenticated) headers.authorization = "Bearer exerciser";
  if (scenario.body !== undefined) headers["content-type"] = "application/json";

  return app.request(scenario.path, {
    method: scenario.method,
    headers,
    body: scenario.body === undefined ? undefined : JSON.stringify(scenario.body),
  });
}

async function runCoverage() {
  const names = new Set(scenarios.map((scenario) => scenario.name));
  const expected = ["health", "sessions.list", "sessions.create", "chat.invalid-body", "chat.missing-session"];
  const missing = expected.filter((name) => !names.has(name));
  if (missing.length > 0) throw new Error(`Missing HTTP exerciser scenarios: ${missing.join(", ")}`);
}

async function runAuth() {
  for (const scenario of scenarios) {
    const response = await call(scenario, false);
    if (scenario.protected && response.status !== 401) {
      throw new Error(`${scenario.name}: expected unauthenticated 401, got ${response.status}`);
    }
    if (!scenario.protected && response.status === 401) {
      throw new Error(`${scenario.name}: expected public access, got 401`);
    }
  }
}

async function runEffect() {
  for (const scenario of scenarios) {
    const response = await call(scenario, true);
    if (response.status !== scenario.expectStatus) {
      throw new Error(`${scenario.name}: expected ${scenario.expectStatus}, got ${response.status}: ${await response.text()}`);
    }
  }
}

const { mode } = parseArgs();

try {
  if (mode === "coverage") await runCoverage();
  if (mode === "auth") await runAuth();
  if (mode === "effect") await runEffect();
  console.info(`httpapi-exercise ${mode}: pass (${scenarios.length} scenarios)`);
} catch (error) {
  console.error(`httpapi-exercise ${mode}: fail`);
  console.error(error);
  process.exit(1);
}
