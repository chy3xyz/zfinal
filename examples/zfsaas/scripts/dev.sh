#!/usr/bin/env bash
# Start zfsaas backend + frontend (two processes).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FE="$ROOT/examples/zfsaas/frontend"

echo "==> zfsaas backend (:8080)"
(cd "$ROOT" && CORS_ORIGIN="${CORS_ORIGIN:-http://localhost:3000}" \
  PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://localhost:3000}" \
  zig build run-zfsaas) &
BE_PID=$!

cleanup() { kill "$BE_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "==> waiting for /api/health"
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
    echo "backend ready"
    break
  fi
  sleep 0.5
done

echo "==> frontend (:3000)"
cd "$FE"
if [[ ! -f .env ]]; then cp .env.example .env; fi
if ! grep -q '^ZFINAL_API_URL=' .env 2>/dev/null; then
  echo 'ZFINAL_API_URL=http://127.0.0.1:8080' >> .env
fi
if [[ ! -d node_modules ]]; then npm install; fi
npm run dev
