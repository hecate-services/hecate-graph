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
FROM docker.io/erlang:28-alpine AS builder
WORKDIR /build

# openssl-dev/zstd-dev/snappy-dev/lz4-dev: hecate_om pulls in rocksdb (via
# barrel_docdb) and khepri/ra transitively, UNCONDITIONALLY, on top of
# CozoDB's own RocksDB backend — confirmed as a real, previously-shipped
# incident on a sibling hecate-services repo with no store of its own
# (hecate-om's own service template, priv/templates/hecate_service/Containerfile).
#
# clang-dev: `cozo`'s `storage-rocksdb` feature pulls in `cozorocks`, which
# uses `bindgen` at build time to generate Rust FFI bindings against
# RocksDB's C++ headers. `bindgen` needs `libclang.so` to do that — without
# it the build fails in a dependency's build.rs before this repo's own code
# ever compiles, with "Unable to find libclang" (verified directly: a local
# `cargo check` against this exact Cargo.toml failed exactly this way on a
# machine with no `clang`/`clang-dev` installed).
RUN apk add --no-cache git curl bash build-base cmake perl linux-headers \
        openssl-dev zstd-dev snappy-dev lz4-dev clang-dev
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

COPY rebar.config ./
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
# LINKS THE PACKAGE TO THE REPOSITORY. On registries that read it, ghcr among
# them, a package without this label is an orphan: it does not appear on the
# repository page and does not inherit its visibility. Matches the pattern
# every hecate_om-scaffolded sibling carries.
LABEL org.opencontainers.image.source="https://github.com/hecate-services/hecate-graph"
# zstd-libs/snappy/lz4-libs: the RUNTIME shared libraries for rocksdb's
# compression backends, compiled against in the builder stage above via
# their -dev packages. Missing here crashes the release outright on boot --
# rocksdb's on_load NIF init fails with "Failed to load NIF library: Error
# loading shared library liblz4.so.1: No such file or directory" -- a
# previously-shipped incident on a sibling repo, see the builder stage.
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl ca-certificates curl \
        zstd-libs snappy lz4-libs
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
