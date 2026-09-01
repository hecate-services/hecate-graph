# hecate-graph — embeddable relational-graph database (CozoDB) as a mesh service.
#
# Each instance runs its own CozoDB on local disk (RocksDB) and exposes mesh
# procedures for querying and learning associations. Consumers compose knowledge
# graphs from distinct sources via mesh_call fan-out and/or entity_learned /
# link_learned fact streams.
#
# Depends on hecate_om, which brings the macula mesh SDK and its Rust QUIC NIF.
# The hecate_graph CozoDB NIF is also built from source (never a fetched
# artifact), the same pattern as reckon-db.
#
# Pushed to ghcr.io/hecate-services/hecate-graph:latest + :semver.

#----------------------------------------------------------------------
# Stage 1 — builder: Erlang + Rust + rebar3 + deps + release
#----------------------------------------------------------------------
FROM docker.io/erlang:27-alpine AS builder
WORKDIR /build

RUN apk add --no-cache git curl bash build-base cmake perl linux-headers
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTFLAGS="-C target-feature=-crt-static"
ENV MACULA_FORCE_SOURCE_BUILD=1
RUN ln -sf /root/.cargo/bin/rustup /usr/local/bin/cargo \
    && ln -sf /root/.cargo/bin/rustup /usr/local/bin/rustc \
    && ln -sf /root/.cargo/bin/rustup /usr/local/bin/rustup \
    && cargo --version && rustc --version

RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

COPY rebar.config rebar.lock ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
COPY native ./native
COPY priv ./priv
RUN rebar3 as prod release

#----------------------------------------------------------------------
# Stage 2 — runtime: bare Alpine + the assembled release
#----------------------------------------------------------------------
FROM docker.io/alpine:3.22
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl ca-certificates curl
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/hecate_graph ./
RUN mkdir -p /var/lib/hecate-graph

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV HECATE_NODE_NAME=hecate_graph
ENV HECATE_NODE_HOST=127.0.0.1
ENV HECATE_COOKIE=hecate_graph
ENV HECATE_HEALTH_PORT=8482

VOLUME ["/etc/hecate/secrets", "/var/lib/hecate-graph"]

EXPOSE 8482
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${HECATE_HEALTH_PORT}/health" || exit 1

ENTRYPOINT ["/app/bin/hecate_graph"]
CMD ["foreground"]
