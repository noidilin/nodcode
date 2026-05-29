import { z } from "zod";

const integerFromString = z.coerce.number().int();
const optionalNonEmptyString = z.preprocess(
  (value) => (value === "" ? undefined : value),
  z.string().min(1).optional(),
);

const runtimeConfigSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  HOST: z.string().min(1).default("0.0.0.0"),
  PORT: integerFromString.min(1).max(65535).default(3000),
  DATABASE_URL: z.string().url(),
  CLERK_SECRET_KEY: z.string().min(1),
  CLERK_PUBLISHABLE_KEY: z.string().min(1),
  POLAR_ACCESS_TOKEN: z.string().min(1),
  POLAR_PRODUCT_ID: z.string().min(1),
  POLAR_CREDITS_METER_ID: z.string().min(1),
  POLAR_SERVER: z.enum(["sandbox", "production"]).default("sandbox"),
  ANTHROPIC_API_KEY: optionalNonEmptyString,
  OPENAI_API_KEY: optionalNonEmptyString,
  AWS_BEARER_TOKEN_BEDROCK: optionalNonEmptyString,
  BEDROCK_AWS_REGION: z.string().min(1).default("ap-northeast-1"),
  BEDROCK_CHAT_MODEL_ID: z
    .string()
    .min(1)
    .default("deepseek.v3.2"),
}).refine(
  (config) =>
    config.ANTHROPIC_API_KEY ||
    config.OPENAI_API_KEY ||
    config.AWS_BEARER_TOKEN_BEDROCK ||
    (config.BEDROCK_AWS_REGION && config.BEDROCK_CHAT_MODEL_ID),
  {
    message: "At least one AI provider must be configured",
    path: ["BEDROCK_CHAT_MODEL_ID"],
  },
);

export type RuntimeConfig = z.infer<typeof runtimeConfigSchema>;

export class RuntimeConfigError extends Error {
  readonly issues: string[];

  constructor(issues: string[]) {
    super(`Invalid runtime configuration: ${issues.join("; ")}`);
    this.name = "RuntimeConfigError";
    this.issues = issues;
  }
}

function formatIssue(issue: z.core.$ZodIssue) {
  const key = issue.path.join(".") || "environment";
  return `${key}: ${issue.message}`;
}

let runtimeConfig: RuntimeConfig | null = null;

export function loadRuntimeConfig(env: NodeJS.ProcessEnv = process.env): RuntimeConfig {
  const result = runtimeConfigSchema.safeParse(env);

  if (!result.success) {
    throw new RuntimeConfigError(result.error.issues.map(formatIssue));
  }

  return result.data;
}

export function initializeRuntimeConfig(env: NodeJS.ProcessEnv = process.env): RuntimeConfig {
  runtimeConfig = loadRuntimeConfig(env);
  return runtimeConfig;
}

export function getRuntimeConfig(): RuntimeConfig {
  if (!runtimeConfig) {
    runtimeConfig = loadRuntimeConfig();
  }

  return runtimeConfig;
}

export function resetRuntimeConfigForTests() {
  runtimeConfig = null;
}
