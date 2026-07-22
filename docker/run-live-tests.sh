#!/usr/bin/env bash
# Run the ZFinal integration test suite against live PG + MySQL.
#
# Prerequisite: docker compose -f docker/test-compose.yml up -d
#
# This script:
#   1. Waits for PG + MySQL healthchecks (max 30s).
#   2. Exports DSN env vars so integration_test.zig's tryOpenPG / tryOpenMY
#      detect the live servers and skip the "no live DB" branch.
#   3. Runs `zig build test` with the PG + MySQL driver flags enabled.
#
# Exit code is the build's exit code (0 = all pass).

set -euo pipefail

cd "$(dirname "$0")/.."

PG_DSN="postgresql://zfinal:zfinal_test_pw@localhost:5432/zfinal_test"
MY_DSN="mysql://zfinal:zfinal_test_pw@localhost:3306/zfinal_test"

# Healthcheck wait — docker-compose's `health` filter is simpler but
# requires Docker 24+; we do explicit polling for portability.
echo "[live-tests] Waiting for PG (5432)..."
for i in $(seq 1 30); do
    if nc -z localhost 5432 2>/dev/null && \
       PGPASSWORD=zfinal_test_pw psql -h localhost -U zfinal -d zfinal_test \
            -c "SELECT 1" >/dev/null 2>&1; then
        echo "[live-tests] PG ready"
        break
    fi
    sleep 1
done

echo "[live-tests] Waiting for MySQL (3306)..."
for i in $(seq 1 30); do
    if nc -z localhost 3306 2>/dev/null && \
       mysqladmin ping -h 127.0.0.1 -uzfinal -pzfinal_test_pw >/dev/null 2>&1; then
        echo "[live-tests] MySQL ready"
        break
    fi
    sleep 1
done

export ZF_PG_HOST="localhost"
export ZF_PG_PORT="5432"
export ZF_PG_USER="zfinal"
export ZF_PG_PASSWORD="zfinal_test_pw"
export ZF_PG_DATABASE="zfinal_test"

export ZF_MY_HOST="localhost"
export ZF_MY_PORT="3306"
export ZF_MY_USER="zfinal"
export ZF_MY_PASSWORD="zfinal_test_pw"
export ZF_MY_DATABASE="zfinal_test"

echo "[live-tests] Running zig build test with PG + MySQL enabled..."
zig build test \
    -Ddriver_pg=true \
    -Denable-pg=true \
    -Ddriver_mysql=true \
    -Denable-mysql=true \
    -Dpg-include=/opt/homebrew/opt/libpq/include \
    -Dmysql-include=/opt/homebrew/include

echo "[live-tests] Done."
