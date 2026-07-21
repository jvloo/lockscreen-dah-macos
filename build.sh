#!/bin/bash
# Build LockscreenDah.app from the SPM executable.
#   ./build.sh            -> build/LockscreenDah.app
#   ./build.sh --install  -> also (re)install to /Applications and relaunch
set -euo pipefail
cd "$(dirname "$0")"

EXECUTABLE="LockscreenDah"       # binary / SPM target (ASCII-safe)
BUNDLE_NAME="Lockscreen Dah"     # on-disk app name (matches Info.plist)
APP="build/$BUNDLE_NAME.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXECUTABLE" "$APP/Contents/MacOS/"
# Symbol tables are ~half the binary; the .dSYM in .build/release keeps
# crash logs symbolicatable.
strip "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/"
if [ -d Resources/FaceEmbedding.mlmodelc ]; then
  cp -R Resources/FaceEmbedding.mlmodelc "$APP/Contents/Resources/"
else
  echo "warning: Resources/FaceEmbedding.mlmodelc missing — run scripts/fetch-model.sh first." >&2
  echo "         The app will fall back to presence-only detection (any face counts)." >&2
fi

# Hardened Runtime (--options runtime): makes the loader ignore
# DYLD_INSERT_LIBRARIES and enforce library validation, so local code can't
# inject a dylib into this always-camera-on process to ride its TCC grant.
# Apple-signed dlopen (login.framework), Core ML, and AVFoundation are all
# unaffected. The app loads no third-party dylibs, so nothing else breaks.
codesign --force --options runtime \
  --entitlements Resources/LockscreenDah.entitlements --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  rm -rf "/Applications/$BUNDLE_NAME.app" "/Applications/Lockscreen Dah?.app" "/Applications/LockscreenDah.app"
  cp -R "$APP" "/Applications/$BUNDLE_NAME.app"
  echo "Installed /Applications/$BUNDLE_NAME.app"
  open "/Applications/$BUNDLE_NAME.app"
fi
