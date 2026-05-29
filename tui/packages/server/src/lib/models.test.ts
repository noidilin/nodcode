import { afterEach, describe, expect, test } from "bun:test";
import { DEFAULT_CHAT_MODEL_ID, findSupportedChatModel } from "@nodcode/shared";
import { resetRuntimeConfigForTests } from "../config";
import { resolveChatModel } from "./models";

const baseEnv = {
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
};

afterEach(() => {
  for (const key of Object.keys(baseEnv)) {
    delete process.env[key];
  }
  resetRuntimeConfigForTests();
});

describe("model catalog and resolver", () => {
  test("declares DeepSeek V3.2 on Bedrock as the default test model", () => {
    const model = findSupportedChatModel(DEFAULT_CHAT_MODEL_ID);

    expect(model).toMatchObject({
      id: "bedrock-deepseek-v3-2",
      provider: "bedrock",
      region: "ap-northeast-1",
      underlyingModelId: "deepseek.v3.2",
    });
  });

  test("resolves the Bedrock model without making a provider call", () => {
    Object.assign(process.env, baseEnv);

    const resolved = resolveChatModel("bedrock-deepseek-v3-2");

    expect(resolved.provider).toBe("bedrock");
    expect(resolved.modelId).toBe("bedrock-deepseek-v3-2");
    expect(resolved.region).toBe("ap-northeast-1");
    expect(resolved.providerModelId).toBe("deepseek.v3.2");
  });

  test("rejects Bedrock region drift from the approved catalog entry", () => {
    Object.assign(process.env, {
      ...baseEnv,
      BEDROCK_AWS_REGION: "us-east-1",
    });

    expect(() => resolveChatModel("bedrock-deepseek-v3-2")).toThrow(
      /does not match supported catalog region/,
    );
  });

  test("rejects Bedrock model drift from the approved catalog entry", () => {
    Object.assign(process.env, {
      ...baseEnv,
      BEDROCK_CHAT_MODEL_ID: "us.anthropic.unapproved-model-v1:0",
    });

    expect(() => resolveChatModel("bedrock-deepseek-v3-2")).toThrow(
      /does not match supported catalog model/,
    );
  });
});
