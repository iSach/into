#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Into.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path)" -parse-as-library -O \
    "$ROOT/Sources/"*.swift -o "$APP/Contents/MacOS/Into"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign "${INTO_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
