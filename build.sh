#!/bin/bash
# Builds MicGate.app (Apple silicon + Intel) into ./build from src/main.swift.
# Needs the Xcode Command Line Tools:  xcode-select --install
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
APP="$OUT/MicGate.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Building (Apple silicon)..."
swiftc -O -target arm64-apple-macos13.0 "$HERE/src/main.swift" -o "$OUT/MicGate-arm64"
echo "Building (Intel)..."
swiftc -O -target x86_64-apple-macos13.0 "$HERE/src/main.swift" -o "$OUT/MicGate-x86_64"

lipo -create "$OUT/MicGate-arm64" "$OUT/MicGate-x86_64" -output "$APP/Contents/MacOS/MicGate"
rm -f "$OUT/MicGate-arm64" "$OUT/MicGate-x86_64"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

# Signing. By default the app is ad-hoc signed (no Apple developer account needed),
# but then macOS treats every rebuild as a new app and you must re-allow it under
# Accessibility. To keep that permission across rebuilds, sign with a stable identity:
#   MICGATE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh
# (list yours with: security find-identity -v -p codesigning)
codesign --force --sign "${MICGATE_SIGN_IDENTITY:--}" --identifier local.micgate "$APP"

echo "Built $APP"
