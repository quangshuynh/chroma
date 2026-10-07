#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    echo 'Usage: Scripts/build-app.sh [debug|release]' >&2
    exit 2
fi
swift build -c "$configuration"
bin_path="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/.build/$configuration/Chroma.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/Chroma" "$app_path/Contents/MacOS/Chroma"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
printf 'Built %s\n' "$app_path"
