# Multi-stage build for ZFinal applications
# Build:  docker build -f docker/Dockerfile -t zfinal-app .
# Run:    docker run -p 8080:8080 zfinal-app
#
# Zig MUST match CI (see .github/workflows/ci.yml). Alpine `apk add zig`
# is usually too old for 0.17-dev — we install via zigup.

ARG ZIG_VERSION=0.17.0-dev.1422+e863bf3be

# ── Build stage ──────────────────────────────────────────
FROM alpine:3.21 AS builder
ARG ZIG_VERSION

RUN apk add --no-cache \
    curl \
    xz \
    sqlite-dev \
    git \
    ca-certificates

# Install pinned Zig (same train as CI)
RUN curl -fsSL https://github.com/mlugg/zigup/releases/latest/download/zigup-x86_64-linux.tar.xz \
      | tar -xJ -C /usr/local/bin \
 && zigup fetch "${ZIG_VERSION}" \
 && zigup default "${ZIG_VERSION}" \
 && zig version

WORKDIR /build
COPY . .

RUN zig build -Doptimize=ReleaseSafe

# ── Runtime stage ────────────────────────────────────────
FROM alpine:3.21

RUN apk add --no-cache \
    sqlite-libs \
    libgcc \
    wget

WORKDIR /app

COPY --from=builder /build/zig-out/bin/production /app/server

RUN mkdir -p /app/data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

ENV CORS_ORIGIN=http://127.0.0.1:8080
CMD ["/app/server"]
