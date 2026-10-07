#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
plutil -lint Resources/Info.plist
swift test
Scripts/build-app.sh release
codesign --verify --strict .build/release/Chroma.app
git diff --check
