# zfsaas runtime image (multi-stage build happens on the host, see doc/saas_kit.md).
#
#   # build the binary on the host (Zig 0.17.0-dev.1422, pinned like CI):
#   zig build install-zfsaas        # or: zig build  (installs all examples)
#   docker build -t zfsaas -f Dockerfile .
#   docker run --rm -p 8080:8080 -v zfsaas-data:/data -e JWT_SECRET=... zfsaas
#
# The binary links libsqlite3 + libc dynamically, so the runtime image installs
# sqlite3. Keep the image minimal — no build toolchain required.

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY zfsaas /usr/local/bin/zfsaas

ENV SAAS_DB=/data/saas-kit.db
ENV PUBLIC_BASE_URL=http://localhost:8080
VOLUME /data
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/zfsaas"]
