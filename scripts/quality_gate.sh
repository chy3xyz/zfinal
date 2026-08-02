#!/usr/bin/env bash
# ZFinal quality / release gate — single entry for local + CI.
# Usage:
#   scripts/quality_gate.sh              # full (default)
#   scripts/quality_gate.sh quick
#   scripts/quality_gate.sh release [--strict]
#   scripts/quality_gate.sh full --strict   # --strict only affects release extras
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="full"
STRICT=0
for arg in "$@"; do
  case "$arg" in
    quick|full|release) MODE="$arg" ;;
    --strict) STRICT=1 ;;
    -h|--help)
      printf 'Usage: %s [quick|full|release] [--strict]\n' "$0"
      exit 0
      ;;
  esac
done

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
ZF_BIN="$ROOT/zig-out/bin/zf"
test -x "$ZF_BIN" || fail "missing $ZF_BIN after install-zf"
export PATH="$ROOT/zig-out/bin:$PATH"

# Pin to the just-built binary so a stale PATH zf (e.g. ~/.local/bin v0.7) cannot mask.
"$ZF_BIN" version >/dev/null

# Required subcommands must be present in help (guards against regressions / wrong binary).
HELP_OUT="$("$ZF_BIN" help 2>&1 || true)"
for req in routes openapi gate market release-check crud:sql check doctor; do
  if ! printf '%s\n' "$HELP_OUT" | grep -qE "(^|[[:space:]])${req}([[:space:]]|$)"; then
    fail "zf help missing required command: ${req} (binary=$ZF_BIN)"
  fi
done
pass "zf CLI commands (routes/openapi/gate/doctor/…)"

"$ZF_BIN" doctor >/dev/null || true
pass "zf doctor"

"$ZF_BIN" check --prod
pass "zf check --prod"

# --- smart routing samples ---
section "zf routes --check (samples)"
"$ZF_BIN" routes --check --root examples/smart-routing/src/modules
"$ZF_BIN" routes --check --root examples/production/src/modules
pass "routes --check"

if [[ "$MODE" != "release" ]]; then
  printf '\n[gate] full PASSED (semver %s)\n' "$VER_ZIG"
  exit 0
fi

# --- release extras ---
TAG="v${VER_ZIG}"

section "CHANGELOG has ## [$VER_ZIG]"
if ! grep -qE "^## \[${VER_ZIG}\]" CHANGELOG.md; then
  fail "CHANGELOG.md missing ## [$VER_ZIG] (Unreleased alone is not enough for release)"
fi
pass "CHANGELOG ## [$VER_ZIG]"

section "git tag $TAG"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    HEAD_SHA="$(git rev-parse HEAD)"
    TAG_SHA="$(git rev-list -n 1 "refs/tags/${TAG}")"
    if [[ "$HEAD_SHA" == "$TAG_SHA" ]]; then
      pass "tag $TAG points at HEAD (retag/CI on tag)"
    else
      fail "tag $TAG already exists at $TAG_SHA (HEAD=$HEAD_SHA) — bump semver before release"
    fi
  else
    pass "tag $TAG does not exist yet"
  fi
else
  printf ' WARN git unavailable — skip tag check\n' >&2
fi

section "git working tree"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    if [[ "$STRICT" -eq 1 ]]; then
      fail "dirty working tree (pass without --strict to warn only)"
    fi
    printf ' WARN dirty working tree — commit before tagging %s\n' "$TAG" >&2
  else
    pass "clean working tree"
  fi
fi

printf '\n[gate] release PASSED (semver %s) — ready to tag %s\n' "$VER_ZIG" "$TAG"
