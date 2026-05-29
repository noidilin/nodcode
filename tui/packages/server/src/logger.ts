const SECRET_KEY_PATTERN = /(secret|token|key|password|credential|authorization|cookie)/i;
const URL_CREDENTIAL_PATTERN = /([a-z][a-z0-9+.-]*:\/\/)([^\s/@:]+):([^\s/@]+)@/gi;
const BEARER_PATTERN = /bearer\s+[^\s,;]+/gi;

export type Logger = {
  info(message: string, metadata?: Record<string, unknown>): void;
  error(message: string, metadata?: Record<string, unknown>): void;
};

function sanitizeString(value: string) {
  return value
    .replace(URL_CREDENTIAL_PATTERN, "$1[redacted]:[redacted]@")
    .replace(BEARER_PATTERN, "Bearer [redacted]");
}

export function sanitizeForLog(value: unknown): unknown {
  if (value instanceof Error) {
    return {
      name: value.name,
      message: "[redacted]",
    };
  }

  if (typeof value === "string") {
    return sanitizeString(value);
  }

  if (Array.isArray(value)) {
    return value.map(sanitizeForLog);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => [
        key,
        SECRET_KEY_PATTERN.test(key) ? "[redacted]" : sanitizeForLog(entry),
      ]),
    );
  }

  return value;
}

export const logger: Logger = {
  info(message, metadata) {
    console.info(message, metadata ? sanitizeForLog(metadata) : undefined);
  },
  error(message, metadata) {
    console.error(message, metadata ? sanitizeForLog(metadata) : undefined);
  },
};
