#!/usr/bin/env bash
# ZFinal quality / release gate — single entry for local + CI.
# Usage:
#   scripts/quality_gate.sh              # full (default)
#   scripts/quality_gate.sh quick        # fmt + version + build + test (+ test-zf)
#   scripts/quality_gate.sh release      # full + CHANGELOG + prod contract
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-full}"

pass() { printf '  OK  %s\n' "$1"; }
fail() { printf ' FAIL %s\n' "$1" >&2; exit 1; }
section() { printf '\n==> [gate:%s] %s\n' "$MODE" "$1"; }

# --- version sync (src/version.zig ↔ build.zig.zon) ---
section "version sync"
VER_ZIG="$(sed -n 's/^pub const semver = \"\(.*\)\";/\1/p' src/version.zig | head -1)"
VER_ZON="$(sed -n 's/.*\.version = \"\(.*\)\",/\1/p' build.zig.zon | head -1)"
if [[ -z "$VER_ZIG" || -z "$VER_ZON" ]]; then
  fail "could not parse versions (zig='$VER_ZIG' zon='$VER_ZON')"
fi
if [[ "$VER_ZIG" != "$VER_ZON" ]]; then
  fail "version mismatch: src/version.zig=$VER_ZIG build.zig.zon=$VER_ZON"
fi
pass "semver $VER_ZIG"

# --- fmt ---
section "zig fmt --check"
zig fmt --check src/ tools/ examples/ benchmark/ build.zig
pass "fmt"

# --- build + tests ---
section "zig build"
zig build
pass "build"

section "zig build test"
zig build test
pass "unit tests"

section "zig build test-zf"
zig build test-zf
pass "codegen regression"

if [[ "$MODE" == "quick" ]]; then
  printf '\n[gate] quick PASSED (semver %s)\n' "$VER_ZIG"
  exit 0
fi

# --- ReleaseSafe smoke ---
section "zig build -Doptimize=ReleaseSafe"
zig build -Doptimize=ReleaseSafe
pass "ReleaseSafe"
test -x zig-out/bin/production || fail "missing zig-out/bin/production"
pass "production binary"

# --- CLI + prod contract ---
section "install-zf + zf check --prod"
zig build install-zf
export PATH="$ROOT/zig-out/bin:$PATH"
zf version >/dev/null
zf check --prod
pass "zf check --prod"

# --- smart routing samples ---
section "zf routes --check (samples)"
zf routes --check --root examples/smart-routing/src/modules
zf routes --check --root examples/production/src/modules
pass "routes --check"

if [[ "$MODE" != "release" ]]; then
  printf '\n[gate] full PASSED (semver %s)\n' "$VER_ZIG"
  exit 0
fi

# --- release extras ---
section "CHANGELOG mentions $VER_ZIG or Unreleased"
if ! grep -qE "^## \[($VER_ZIG|Unreleased)\]" CHANGELOG.md; then
  fail "CHANGELOG.md missing ## [$VER_ZIG] or ## [Unreleased]"
fi
pass "CHANGELOG"

section "git working tree (warn only)"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    printf ' WARN dirty working tree — commit before tagging v%s\n' "$VER_ZIG" >&2
  else
    pass "clean working tree"
  fi
fi

printf '\n[gate] release PASSED (semver %s) — ready to tag v%s\n' "$VER_ZIG" "$VER_ZIG"
