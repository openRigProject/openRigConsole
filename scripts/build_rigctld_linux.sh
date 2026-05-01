#!/usr/bin/env bash
# Build rigctld for Linux (x86_64 and arm64) from Hamlib source.
# Output: assets/rigctld/linux/rigctld        (x86_64)
#         assets/rigctld/linux-arm64/rigctld   (arm64, if cross-tools present)
#
# Usage: scripts/build_rigctld_linux.sh [version]
#
# Run natively on a Linux x86_64 machine, or inside Docker:
#   docker run --rm -v "$PWD":/app -w /app debian:bookworm bash scripts/build_rigctld_linux.sh
#
# Requirements (apt): build-essential autoconf automake libtool
#                     libusb-1.0-0-dev libreadline-dev
# For arm64 cross-build: gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu

set -euo pipefail

HAMLIB_VERSION="${1:-4.7.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARBALL="/tmp/hamlib-${HAMLIB_VERSION}.tar.gz"
TARBALL_URL="https://github.com/Hamlib/Hamlib/releases/download/${HAMLIB_VERSION}/hamlib-${HAMLIB_VERSION}.tar.gz"

# Install build deps if running as root (e.g. inside Docker)
if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq \
    build-essential autoconf automake libtool \
    libusb-1.0-0-dev libreadline-dev curl \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu 2>/dev/null || true
fi

if [[ ! -f "$TARBALL" ]]; then
  echo "==> Downloading Hamlib ${HAMLIB_VERSION}…"
  curl -L --progress-bar -o "$TARBALL" "$TARBALL_URL"
fi

# ── Build one arch ─────────────────────────────────────────────────────────

build_arch() {
  local ARCH="$1"        # x86_64 | aarch64
  local HOST="$2"        # configure --host triple
  local OUTPUT_DIR="$3"

  echo
  echo "==> Building ${ARCH}…"
  mkdir -p "$OUTPUT_DIR"

  local SRC="/tmp/hamlib-src-${ARCH}-$$"
  mkdir -p "$SRC"
  tar -xzf "$TARBALL" -C "$SRC" --strip-components=1

  (
    cd "$SRC"
    ./configure \
      --host="$HOST" \
      --disable-shared \
      --enable-static \
      --without-cxx-binding \
      --disable-winradio \
      CFLAGS="-O2" \
      2>&1 | grep -E "^(error|configure:.*error)" | tail -5

    make -j"$(nproc 2>/dev/null || echo 4)" -C src 2>&1 | tail -1
    make -j"$(nproc 2>/dev/null || echo 4)" -C tests rigctld 2>&1 | tail -1
  )

  local BIN
  BIN=$(find "$SRC/tests" "$SRC" -name "rigctld" -type f -perm /111 2>/dev/null | head -1)
  if [[ -z "$BIN" ]]; then
    echo "ERROR: binary not found for ${ARCH}"
    exit 1
  fi

  strip "$BIN" 2>/dev/null || true
  cp "$BIN" "$OUTPUT_DIR/rigctld"
  chmod 755 "$OUTPUT_DIR/rigctld"
  rm -rf "$SRC"
  echo "==> ${OUTPUT_DIR}/rigctld: $(file "$OUTPUT_DIR/rigctld")"
}

# Native x86_64
build_arch x86_64 "x86_64-linux-gnu" "$REPO_ROOT/assets/rigctld/linux"

# Cross-compile arm64 (only if cross-compiler is installed)
if command -v aarch64-linux-gnu-gcc &>/dev/null; then
  build_arch aarch64 "aarch64-linux-gnu" "$REPO_ROOT/assets/rigctld/linux-arm64"
else
  echo
  echo "NOTE: aarch64-linux-gnu-gcc not found — skipping arm64 build."
  echo "      Install gcc-aarch64-linux-gnu to enable arm64."
fi

echo
echo "==> Linux rigctld build complete."
