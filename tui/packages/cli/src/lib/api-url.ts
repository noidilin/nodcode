const DEFAULT_API_URL = "http://localhost:3000";

export function getApiUrl(env: NodeJS.ProcessEnv = process.env) {
  return (env.API_URL ?? DEFAULT_API_URL).replace(/\/+$/, "");
}
