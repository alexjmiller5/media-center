#!/bin/bash
# Release gate: the signed app's identity must reach the Data Protection Keychain.
# Run in a logged-in user context with the distribution identity in the search list.
set -euo pipefail
APP_PATH=$1
IDENTITY=$2
ENTITLEMENTS=$3
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/media-center-keychain-probe.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
swift build -c release --package-path scripts/keychain-probe --scratch-path "$ROOT/build"
PROBE="$ROOT/KeychainProbe.app"
mkdir -p "$PROBE/Contents/MacOS"
cp "$APP_PATH/Contents/Info.plist" "$PROBE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable KeychainProbe' "$PROBE/Contents/Info.plist"
if [[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]]; then
  cp "$APP_PATH/Contents/embedded.provisionprofile" "$PROBE/Contents/embedded.provisionprofile"
fi
cp "$ROOT/build/release/KeychainProbe" "$PROBE/Contents/MacOS/KeychainProbe"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$PROBE"
codesign --verify --strict "$PROBE"
"$PROBE/Contents/MacOS/KeychainProbe"
