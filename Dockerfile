FROM rust:1-bookworm AS builder

WORKDIR /app
COPY . .

RUN cargo build --release --locked --bin biomcp

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system biomcp \
    && useradd --system --gid biomcp --home-dir /home/biomcp --create-home biomcp

COPY --from=builder /app/target/release/biomcp /usr/local/bin/biomcp

ENV PORT=8080 \
    BIOMCP_CACHE_DIR=/tmp/biomcp/cache \
    XDG_CACHE_HOME=/tmp/xdg-cache \
    XDG_DATA_HOME=/tmp/xdg-data \
    RUST_LOG=warn

EXPOSE 8080

USER biomcp

CMD ["sh", "-c", "exec biomcp serve-http --host 0.0.0.0 --port ${PORT:-8080}"]
