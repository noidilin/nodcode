import { createClerkClient } from "@clerk/backend";
import { getRuntimeConfig } from "../config";

let clerkClient: ReturnType<typeof createClerkClient> | null = null;

function getClerkClient() {
  if (!clerkClient) {
    const config = getRuntimeConfig();
    clerkClient = createClerkClient({
      secretKey: config.CLERK_SECRET_KEY,
      publishableKey: config.CLERK_PUBLISHABLE_KEY,
    });
  }

  return clerkClient;
}

export async function authenticateOAuthRequest(request: Request) {
  const requestState = await getClerkClient().authenticateRequest(request, {
    acceptsToken: "oauth_token",
  });

  if (!requestState.isAuthenticated) {
    return null;
  }

  const auth = requestState.toAuth();
  if (auth.tokenType !== "oauth_token" || !auth.userId) {
    return null;
  }

  return { userId: auth.userId };
};
