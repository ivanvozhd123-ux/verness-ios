#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "A Mac with Xcode 15+ and the iOS SDK is required. This script cannot build iOS on Windows." >&2
  exit 1
fi
xcodebuild -project verness.xcodeproj -scheme verness -sdk iphonesimulator -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
