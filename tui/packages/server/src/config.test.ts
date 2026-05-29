import { describe, expect, test } from "bun:test";
import { loadRuntimeConfig, RuntimeConfigError } from "./config";

const validEnv: NodeJS.ProcessEnv = {
  NODE_ENV: "production",
  HOST: "127.0.0.1",
  PORT: "8080",
  DATABASE_URL: "postgres://user:pass@localhost:5432/nodcode",
  CLERK_SECRET_KEY: "sk_test_secret-value",
  CLERK_PUBLISHABLE_KEY: "pk_test_public-value",
  POLAR_ACCESS_TOKEN: "polar-secret-value",
  POLAR_PRODUCT_ID: "product_123",
  POLAR_CREDITS_METER_ID: "meter_123",
  POLAR_SERVER: "sandbox",
  ANTHROPIC_API_KEY: "anthropic-secret-value",
};

describe("runtime configuration", () => {
  test("parses production-like configuration", () => {
    const config = loadRuntimeConfig(validEnv);

    expect(config.PORT).toBe(8080);
    expect(config.HOST).toBe("127.0.0.1");
    expect(config.POLAR_SERVER).toBe("sandbox");
  });

  test("reports missing or invalid fields without secret values", () => {
    const env: NodeJS.ProcessEnv = {
      ...validEnv,
      DATABASE_URL: "not-a-url",
      CLERK_SECRET_KEY: "super-secret-value",
      PORT: "70000",
    };
    delete env.POLAR_ACCESS_TOKEN;

    expect(() => loadRuntimeConfig(env)).toThrow(RuntimeConfigError);

    try {
      loadRuntimeConfig(env);
    } catch (error) {
      expect(error).toBeInstanceOf(RuntimeConfigError);
      const message = String((error as Error).message);

      expect(message).toContain("DATABASE_URL");
      expect(message).toContain("PORT");
      expect(message).toContain("POLAR_ACCESS_TOKEN");
      expect(message).not.toContain("super-secret-value");
    }
  });

  test("defaults the Bedrock provider configuration for ECS task-role credentials", () => {
    const { ANTHROPIC_API_KEY, OPENAI_API_KEY, AWS_BEARER_TOKEN_BEDROCK, ...env } = validEnv;

    const config = loadRuntimeConfig(env);

    expect(config.BEDROCK_AWS_REGION).toBe("ap-northeast-1");
    expect(config.BEDROCK_CHAT_MODEL_ID).toBe("deepseek.v3.2");
  });
});
