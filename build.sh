#!/bin/bash
# Builds EasyDL.app. Needs nothing but the Xcode command line tools.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/EasyDL.app"
CONTENTS="$APP/Contents"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/EasyDL"

echo "==> Self-test"
"$BIN" --self-test

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/EasyDL"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$ROOT/EasyDLArt/EasyDL.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "==> Signing"
# Ad-hoc signature: enough to run locally and to keep a stable identity across
# rebuilds. Replace "-" with a Developer ID to hand the app to anyone else.
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo ""
echo "Built $APP"
echo "Run it:      open '$APP'"
echo "Install it:  cp -R '$APP' /Applications/"
