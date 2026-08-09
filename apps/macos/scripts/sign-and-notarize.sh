#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 'Developer ID Application: Name (TEAMID)' keychain-profile /path/to/app" >&2
  exit 2
fi
identity="$1"
profile="$2"
app_path="$3"
codesign --force --deep --options runtime --timestamp --sign "$identity" "$app_path"
archive="${app_path%.app}.zip"
ditto -c -k --keepParent "$app_path" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
