import { describe, expect, test } from "bun:test";
import { calculateCreditsForUsage } from "./credits";

describe("credit conversion", () => {
  test("converts Bedrock token usage through catalog pricing", () => {
    const result = calculateCreditsForUsage({
      provider: "bedrock",
      model: "bedrock-deepseek-v3-2",
      usage: {
        inputTokens: 1_000_000,
        outputTokens: 1_000_000,
        totalTokens: 2_000_000,
      },
    });

    expect(result.credits).toBe(600);
  });
});
