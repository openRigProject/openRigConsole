#!/usr/bin/env bash
# Cross-compile rigctld for Windows x86_64 using MinGW-w64.
# Output: assets/rigctld/windows/rigctld.exe
#
# Usage: scripts/build_rigctld_windows.sh [version]
#
# Run on Linux with MinGW installed:
#   apt-get install -y mingw-w64
#
# Or on macOS with Homebrew:
#   brew install mingw-w64
#
# On macOS, brew only provides x86_64-w64-mingw32 toolchain.

set -euo pipefail

HAMLIB_VERSION="${1:-4.7.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/assets/rigctld/windows"
TARBALL="/tmp/hamlib-${HAMLIB_VERSION}.tar.gz"
TARBALL_URL="https://github.com/Hamlib/Hamlib/releases/download/${HAMLIB_VERSION}/hamlib-${HAMLIB_VERSION}.tar.gz"

# Install deps on Debian/Ubuntu root (Docker)
if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq \
    build-essential autoconf automake libtool \
    mingw-w64 curl 2>/dev/null || true
fi

# Detect MinGW cross-compiler
CROSS=""
for candidate in x86_64-w64-mingw32 x86_64-w64-mingw32-gcc; do
  if command -v "${candidate}-gcc" &>/dev/null 2>&1 || command -v "$candidate" &>/dev/null 2>&1; then
    CROSS="x86_64-w64-mingw32"
    break
  fi
done

if [[ -z "$CROSS" ]]; then
  echo "ERROR: MinGW cross-compiler not found."
  echo "  macOS:  brew install mingw-w64"
  echo "  Linux:  apt-get install mingw-w64"
  exit 1
fi

echo "==> Cross-compiling rigctld for Windows (${CROSS})…"
mkdir -p "$OUTPUT_DIR"

if [[ ! -f "$TARBALL" ]]; then
  echo "==> Downloading Hamlib ${HAMLIB_VERSION}…"
  curl -L --progress-bar -o "$TARBALL" "$TARBALL_URL"
fi

SRC="/tmp/hamlib-src-win-$$"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC" --strip-components=1

(
  cd "$SRC"
  ./configure \
    --host="${CROSS}" \
    --disable-shared \
    --enable-static \
    --without-cxx-binding \
    --disable-winradio \
    --disable-usb-rig \
    CFLAGS="-O2 -DWIN32" \
    2>&1 | grep -E "^(error|configure:.*error)" | tail -5

  make -j"$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)" -C src 2>&1 | tail -1
  make -j"$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)" -C tests rigctld 2>&1 | tail -1
)

BIN=$(find "$SRC/tests" "$SRC" -name "rigctld.exe" -type f 2>/dev/null | head -1)
if [[ -z "$BIN" ]]; then
  # MinGW may not append .exe in all configs
  BIN=$(find "$SRC/tests" "$SRC" -name "rigctld" -type f 2>/dev/null | head -1)
fi

if [[ -z "$BIN" ]]; then
  echo "ERROR: rigctld.exe not found after build"
  find "$SRC" -name "rigctld*" 2>/dev/null | head -10
  exit 1
fi

${CROSS}-strip "$BIN" 2>/dev/null || strip "$BIN" 2>/dev/null || true
cp "$BIN" "$OUTPUT_DIR/rigctld.exe"
chmod 755 "$OUTPUT_DIR/rigctld.exe"
rm -rf "$SRC"

echo
echo "==> Done!"
file "$OUTPUT_DIR/rigctld.exe"
