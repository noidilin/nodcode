#!/usr/bin/env sh
set -eu

IMAGE_NAME="${IMAGE_NAME:-nodcode-api:smoke}"
CONTAINER_NAME="${CONTAINER_NAME:-nodcode-api-smoke}"
HOST_PORT="${HOST_PORT:-3000}"
CONTAINER_PORT="${CONTAINER_PORT:-3000}"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

cleanup

docker build -f Dockerfile -t "$IMAGE_NAME" .

docker run -d \
  --name "$CONTAINER_NAME" \
  -p "${HOST_PORT}:${CONTAINER_PORT}" \
  -e NODE_ENV=production \
  -e HOST=0.0.0.0 \
  -e PORT="$CONTAINER_PORT" \
  -e DATABASE_URL=postgresql://nodcode:nodcode@localhost:5432/nodcode \
  -e CLERK_SECRET_KEY=sk_test_container_smoke \
  -e CLERK_PUBLISHABLE_KEY=pk_test_container_smoke \
  -e POLAR_ACCESS_TOKEN=polar_container_smoke \
  -e POLAR_PRODUCT_ID=product_container_smoke \
  -e POLAR_CREDITS_METER_ID=meter_container_smoke \
  -e POLAR_SERVER=sandbox \
  -e BEDROCK_AWS_REGION=us-east-1 \
  -e BEDROCK_CHAT_MODEL_ID=anthropic.claude-3-5-sonnet-20241022-v2:0 \
  "$IMAGE_NAME" >/dev/null

attempt=1
while [ "$attempt" -le 30 ]; do
  if bun -e "const r = await fetch('http://127.0.0.1:${HOST_PORT}/health'); if (!r.ok) process.exit(1); const body = await r.json(); if (body.status !== 'ok') process.exit(1);" >/dev/null 2>&1; then
    echo "Container smoke check passed: http://127.0.0.1:${HOST_PORT}/health"
    exit 0
  fi

  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
    echo "Container exited before becoming healthy" >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    exit 1
  fi

  attempt=$((attempt + 1))
  sleep 1
done

echo "Timed out waiting for container health endpoint" >&2
docker logs "$CONTAINER_NAME" >&2 || true
exit 1
