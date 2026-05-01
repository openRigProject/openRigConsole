#!/usr/bin/env bash
# Build rigctld for macOS from Hamlib source.
# Output: assets/rigctld/macos/rigctld
#
# On Apple Silicon (arm64): builds a native arm64 binary.
# On Intel (x86_64): builds a native x86_64 binary.
# For a universal binary, run on both machines and lipo the results.
#
# Usage: scripts/build_rigctld_macos.sh [version]
# Requirements (Homebrew): autoconf automake libtool libusb readline

set -euo pipefail

HAMLIB_VERSION="${1:-4.7.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/assets/rigctld/macos"
TARBALL="/tmp/hamlib-${HAMLIB_VERSION}.tar.gz"
TARBALL_URL="https://github.com/Hamlib/Hamlib/releases/download/${HAMLIB_VERSION}/hamlib-${HAMLIB_VERSION}.tar.gz"

NATIVE_ARCH="$(uname -m)"   # arm64 or x86_64
echo "==> Hamlib ${HAMLIB_VERSION} — native ${NATIVE_ARCH} → ${OUTPUT_DIR}/rigctld"
mkdir -p "$OUTPUT_DIR"

# ── Download ──────────────────────────────────────────────────────────────────

if [[ ! -f "$TARBALL" ]]; then
  echo "==> Downloading…"
  curl -L --progress-bar -o "$TARBALL" "$TARBALL_URL"
else
  echo "==> Using cached tarball"
fi

# ── Detect Homebrew prefix ────────────────────────────────────────────────────

BREW_PREFIX="$(brew --prefix)"
LIBUSB_PREFIX="$(brew --prefix libusb 2>/dev/null || echo "$BREW_PREFIX")"
READLINE_PREFIX="$(brew --prefix readline 2>/dev/null || echo "$BREW_PREFIX")"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# ── Extract + build ───────────────────────────────────────────────────────────

SRC="/tmp/hamlib-src-$$"
mkdir -p "$SRC"
tar -xzf "$TARBALL" -C "$SRC" --strip-components=1

CFLAGS="-O2 -isysroot ${SDK} -mmacosx-version-min=12.0 -I${LIBUSB_PREFIX}/include -I${READLINE_PREFIX}/include"
LDFLAGS="-isysroot ${SDK} -L${LIBUSB_PREFIX}/lib -L${READLINE_PREFIX}/lib"

echo "==> Configuring…"
(
  cd "$SRC"
  ./configure \
    --disable-shared \
    --enable-static \
    --without-cxx-binding \
    --disable-winradio \
    CFLAGS="$CFLAGS" \
    LDFLAGS="$LDFLAGS" \
    RANLIB="ranlib -no_warning_for_no_symbols" \
    2>&1 | grep -E "^(checking for (usb|readline)|Enable|error)" | tail -8
)

echo "==> Building library…"
make -j"$(sysctl -n hw.logicalcpu)" -C "$SRC/src" 2>&1 | tail -2

echo "==> Building rigctld…"
make -j"$(sysctl -n hw.logicalcpu)" -C "$SRC/tests" rigctld 2>&1 | tail -2

# ── Install ───────────────────────────────────────────────────────────────────

BIN=$(find "$SRC/tests" -name "rigctld" -type f -perm +111 2>/dev/null | head -1)
if [[ -z "$BIN" ]]; then
  echo "ERROR: rigctld binary not found"
  find "$SRC" -name "rigctld*" 2>/dev/null | head -10
  exit 1
fi

cp "$BIN" "$OUTPUT_DIR/rigctld"
chmod 755 "$OUTPUT_DIR/rigctld"
strip "$OUTPUT_DIR/rigctld" 2>/dev/null || true
codesign --force --sign - "$OUTPUT_DIR/rigctld"
rm -rf "$SRC"

echo
echo "==> Done!"
file "$OUTPUT_DIR/rigctld"
"$OUTPUT_DIR/rigctld" --version 2>/dev/null | head -1 || true
