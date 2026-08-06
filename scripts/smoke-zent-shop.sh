#!/usr/bin/env bash
# Smoke test for examples/zent-shop (ZFinal × zent v0.29).
# Builds the demo, boots it, and asserts the HTTP contract end-to-end:
#   create user (unique dedup) · product · cart · transactional checkout ·
#   pagination meta · composite-unique dedup · data_scope own-orders.
# Usage: bash scripts/smoke-zent-shop.sh   (from repo root)
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${ZENT_SMOKE_PORT:-18285}"
B="http://127.0.0.1:${PORT}"

echo "== build =="
(cd examples/zent-shop && zig build)

echo "== boot =="
rm -f examples/zent-shop/zent-shop.db
cd examples/zent-shop
HTTP_PORT="$PORT" ./zig-out/bin/zent-shop > /tmp/zent-shop-smoke.log 2>&1 &
SERVER_PID=$!
cd ..
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; rm -f examples/zent-shop/zent-shop.db' EXIT
sleep 1.5

pass=0
check() { # name, expected-substring, actual
    if echo "$3" | grep -qF "$2"; then
        pass=$((pass + 1)); echo "  ✓ $1"
    else
        echo "  ✗ $1 (expected '$2', got: $3)"; exit 1
    fi
}

echo "== assertions =="
check "user created" '{"ok":true,"id":1}' "$(curl -s --max-time 5 -X POST "$B/api/v1/users?name=A&handle=a&email=a@x.com")"
TOKEN=$(curl -s --max-time 5 -X POST "$B/api/v1/auth/login?handle=a" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
check "login issues JWT (JWT header prefix)" 'eyJ' "$TOKEN"
check "unique handle dedup" 'Duplicate' "$(curl -s --max-time 5 -X POST "$B/api/v1/users?name=B&handle=a&email=b@x.com")"
check "product created" '{"ok":true,"id":1}' "$(curl -s --max-time 5 -X POST "$B/api/v1/products?seller_id=1&name=W&price_cents=100&stock=5")"
check "cart item added" '{"ok":true,"id":1}' "$(curl -s --max-time 5 -X POST "$B/api/v1/cart_items?user_id=1&product_id=1&qty=2")"
check "checkout tx" '{"ok":true,"order_id":1}' "$(curl -s --max-time 5 -X POST "$B/api/v1/orders/checkout?user_id=1")"
check "stock decremented" '"stock":3' "$(curl -s --max-time 5 "$B/api/v1/products?seller_id=1")"
check "pagination meta" '"meta":{"total":1,"page":1,"size":2}' "$(curl -s --max-time 5 "$B/api/v1/products?seller_id=1&page=1&size=2")"
check "follow ok" '{"ok":true,"id":1}' "$(curl -s --max-time 5 -X POST "$B/api/v1/follows?follower_id=1&followee_id=2")"
check "composite unique dedup" 'Duplicate' "$(curl -s --max-time 5 -X POST "$B/api/v1/follows?follower_id=1&followee_id=2")"
check "data_scope own order" '"buyer_id":1' "$(curl -s --max-time 5 -H "Authorization: Bearer $TOKEN" "$B/api/v1/orders/mine")"
check "mine rejects missing token" 'Unauthorized' "$(curl -s --max-time 5 "$B/api/v1/orders/mine")"

echo "== smoke: ${pass}/12 passed =="
