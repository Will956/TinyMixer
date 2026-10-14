#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
APP="build/TinyMixer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos14.2" \
    -o "$APP/Contents/MacOS/TinyMixer" \
    Sources/*.swift

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
