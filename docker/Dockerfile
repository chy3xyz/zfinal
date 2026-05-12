# Multi-stage build for ZFinal applications
# Build:  docker build -f docker/Dockerfile -t zfinal-app .
# Run:    docker run -p 8080:8080 zfinal-app

# ── Build stage ──────────────────────────────────────────
FROM alpine:3.21 AS builder

RUN apk add --no-cache \
    zig \
    sqlite-dev \
    git

WORKDIR /build
COPY . .

# Build the production example (or replace with your app)
RUN zig build -Doptimize=ReleaseSafe

# ── Runtime stage ────────────────────────────────────────
FROM alpine:3.21

RUN apk add --no-cache \
    sqlite-libs \
    libgcc

WORKDIR /app

# Copy binary
COPY --from=builder /build/zig-out/bin/production /app/server

# Copy templates and static files (if any)
COPY --from=builder /build/examples/production/ /app/
COPY --from=builder /build/src/templates/ /app/templates/ 2>/dev/null || true
COPY --from=builder /build/static/ /app/static/ 2>/dev/null || true

# Create data directory for SQLite
RUN mkdir -p /app/data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["/app/server"]
