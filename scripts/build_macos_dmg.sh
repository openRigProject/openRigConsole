#!/bin/bash
# build_macos_dmg.sh — Build openRig Console and package as a macOS DMG installer.
#
# Usage:
#   ./scripts/build_macos_dmg.sh [--skip-build]
#
#   --skip-build   Skip the flutter build step (use existing build/macos/Build/Products/Release/)
#
# Output: build/openRigConsole-<version>.dmg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

SKIP_BUILD=0
for arg in "$@"; do
  [ "$arg" = "--skip-build" ] && SKIP_BUILD=1
done

# Read version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)
APP_NAME="openRig Console"
APP_BUNDLE="openrig_console.app"
DMG_NAME="openRigConsole-${VERSION}"
DMG_PATH="build/${DMG_NAME}.dmg"
RELEASE_DIR="build/macos/Build/Products/Release"

echo "==> openRig Console macOS DMG builder"
echo "    Version : ${VERSION}"
echo "    Output  : ${DMG_PATH}"

# ── 1. Build ──────────────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> Building Flutter release..."
  flutter build macos --release
else
  echo "==> Skipping build (--skip-build)"
fi

APP_SRC="${RELEASE_DIR}/${APP_BUNDLE}"
if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: App bundle not found at ${APP_SRC}" >&2
  exit 1
fi

# ── 2. Stage DMG contents ─────────────────────────────────────────────────────
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging DMG contents..."
cp -R "$APP_SRC" "$STAGING/${APP_BUNDLE}"
ln -s /Applications "$STAGING/Applications"

# ── 3. Create read-write DMG ──────────────────────────────────────────────────
TMP_DMG="build/${DMG_NAME}-tmp.dmg"
rm -f "$TMP_DMG" "$DMG_PATH"

# Size: app bundle + 20 MB headroom
APP_MB=$(du -sm "$STAGING/${APP_BUNDLE}" | awk '{print $1}')
DMG_MB=$(( APP_MB + 20 ))

echo "==> Creating temporary read-write DMG (${DMG_MB} MB)..."
hdiutil create \
  -srcfolder "$STAGING" \
  -volname "$APP_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,b=16" \
  -format UDRW \
  -size "${DMG_MB}m" \
  "$TMP_DMG" > /dev/null

# ── 4. Mount and configure window appearance ──────────────────────────────────
echo "==> Configuring DMG window..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" \
  | awk '/\/Volumes\//{print $NF}')

# Give Finder a moment to register the volume
sleep 1

osascript <<APPLESCRIPT || echo "  (Finder window styling skipped — headless environment)"
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 820, 460}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "${APP_BUNDLE}" of container window to {160, 170}
    set position of item "Applications" of container window to {460, 170}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

# Hide the background folder if present, sync
sync

# ── 5. Detach and convert to compressed read-only DMG ────────────────────────
echo "==> Converting to compressed DMG..."
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" > /dev/null
rm -f "$TMP_DMG"

echo ""
echo "✓ Done: ${DMG_PATH}"
echo "  Size : $(du -sh "$DMG_PATH" | awk '{print $1}')"
