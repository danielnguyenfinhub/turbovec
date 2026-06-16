#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# Installs the system + toolchain dependencies turbovec needs so that
# `cargo test`, `cargo clippy`, `maturin build`, and `pytest` all work in a
# fresh remote container. Safe to run multiple times (idempotent).
set -euo pipefail

# Only run in the remote (Claude Code on the web) environment. On a local
# machine we assume the developer manages their own dependencies.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# 1. System BLAS provider + pkg-config.
#
# ndarray's `blas` feature links against C-BLAS (OpenBLAS on Linux); the
# turbovec build script emits `cargo:rustc-link-lib=openblas`, so the dev
# headers must be present or every `cargo test`/`cargo build` fails to link.
if ! pkg-config --exists openblas 2>/dev/null; then
  echo "Installing libopenblas-dev + pkg-config..."
  export DEBIAN_FRONTEND=noninteractive
  # Tolerate failures from preconfigured third-party PPAs (e.g. deadsnakes,
  # ondrej/php) that aren't reachable under the remote network policy — the
  # main Ubuntu archives still refresh and that's where libopenblas-dev lives.
  sudo apt-get update || true
  sudo apt-get install -y libopenblas-dev pkg-config
fi

# 2. maturin — builds the PyO3 extension wheel for the Python bindings.
#    The `[patchelf]` extra pulls in patchelf, which maturin needs to bundle
#    the OpenBLAS shared library into the Linux wheel.
if ! command -v maturin >/dev/null 2>&1; then
  echo "Installing maturin..."
  python3 -m pip install "maturin[patchelf]"
fi

# 3. Warm the Cargo build cache so the first test run in-session is fast.
#    The container state is cached after the hook completes, so this work
#    is reused by later sessions.
echo "Fetching + building Rust workspace..."
cargo fetch --manifest-path "$PROJECT_DIR/Cargo.toml"
cargo build -p turbovec --release --manifest-path "$PROJECT_DIR/Cargo.toml"

# 4. Build + install the Python extension so `import turbovec` works in the
#    pytest suite. Mirror CI: build a wheel, then pip-install it (works with
#    the system Python as root, no virtualenv required).
echo "Building + installing turbovec Python extension..."
python3 -m pip install pytest
maturin build --release --out "$PROJECT_DIR/turbovec-python/dist" \
  --manifest-path "$PROJECT_DIR/turbovec-python/Cargo.toml"
python3 -m pip install --force-reinstall "$PROJECT_DIR"/turbovec-python/dist/*.whl

echo "Session setup complete."
