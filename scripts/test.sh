#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 -m unittest discover -s Server -p 'test_*.py' -v
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Server tests finished. XCTest requires a Mac with Xcode." >&2
  exit 1
fi
device=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for group in d["devices"].values() for v in group if "iPhone" in v["name"]))')
xcodebuild -project verness.xcodeproj -scheme verness -destination "platform=iOS Simulator,id=$device" -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
