#!/bin/sh
# Build the CozoDB NIF for hecate-graph.
#
# Same pattern as reckon-db's priv/build-nifs.sh: idempotent, tolerates
# a missing Rust toolchain (logs a warning and continues — the Erlang
# wrapper returns {error, nif_not_loaded}).
set -eu

BUILD_DIR="${1:-.}"
NIF_DIR="${BUILD_DIR:-.}/native/hecate_graph_nif"
PRIV_DIR="${BUILD_DIR:-.}/priv"

if ! command -v cargo >/dev/null 2>&1; then
    echo "[hecate-graph] Rust toolchain not found — CozoDB NIF will not be built." >&2
    echo "[hecate-graph] hecate_graph_nif:run_query/3 will return {error, nif_not_loaded}." >&2
    exit 0
fi

echo "[hecate-graph] Building CozoDB NIF..."
cd "$NIF_DIR"
# `set -eu` only tolerates a MISSING cargo (checked above) -- an installed
# cargo whose build genuinely fails (e.g. no libclang for cozorocks'
# bindgen step) used to abort this whole script, which is a `pre_hooks`
# compile hook: that took down `rebar3 compile` entirely instead of
# degrading to the documented {error, nif_not_loaded} fallback. Guarding
# the one command that can legitimately fail keeps `set -e` for everything
# else in this script.
if ! cargo build --release; then
    echo "[hecate-graph] WARNING: CozoDB NIF build failed -- continuing without it." >&2
    echo "[hecate-graph] hecate_graph_nif:run_query/3 will return {error, nif_not_loaded}." >&2
    exit 0
fi

OS=$(uname -s)
ARCH=$(uname -m)
case "$OS" in
    Linux)  EXT="so" ;;
    Darwin) EXT="dylib" ;;
    *)      EXT="so" ;;
esac

LIB_PATH="target/release/libhecate_graph_nif.${EXT}"
if [ -f "$LIB_PATH" ]; then
    mkdir -p "$PRIV_DIR"
    cp "$LIB_PATH" "$PRIV_DIR/hecate_graph_nif.${EXT}"
    echo "[hecate-graph] CozoDB NIF installed to $PRIV_DIR/hecate_graph_nif.${EXT}"
else
    echo "[hecate-graph] WARNING: NIF binary not found at $LIB_PATH" >&2
fi
