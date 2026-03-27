# ── Stage 1: Builder ─────────────────────────────────────────────────
FROM debian:bookworm-slim AS builder

ARG ZIG_VERSION=0.14.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
        libsecp256k1-dev \
        libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Zig
RUN ARCH="$(dpkg --print-architecture)" && \
    case "${ARCH}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "Unsupported arch: ${ARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /usr/local --strip-components=1

WORKDIR /build
COPY . .

RUN zig build -Doptimize=ReleaseSafe -Dsecp256k1=true

# ── Stage 2: Runtime ─────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

LABEL org.opencontainers.image.title="rippled-zig" \
      org.opencontainers.image.description="XRP Ledger node implementation in Zig" \
      org.opencontainers.image.source="https://github.com/seancollins/rippled-zig" \
      org.opencontainers.image.licenses="ISC"

RUN apt-get update && apt-get install -y --no-install-recommends \
        libsecp256k1-1 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN groupadd --gid 10001 rippled && \
    useradd --uid 10001 --gid rippled --shell /usr/sbin/nologin --create-home rippled

# Create data directory
RUN mkdir -p /var/lib/rippled && chown rippled:rippled /var/lib/rippled

COPY --from=builder /build/zig-out/bin/rippled-zig /usr/local/bin/rippled-zig

# RPC, Peer protocol, WebSocket
EXPOSE 5005 51235 6006

USER rippled
WORKDIR /var/lib/rippled

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:5005/health || exit 1

ENTRYPOINT ["rippled-zig"]
