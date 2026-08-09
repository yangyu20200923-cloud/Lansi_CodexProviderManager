#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build-app.sh"
app="$project_dir/dist/Codex Provider Manager.app"
test -x "$app/Contents/MacOS/CodexProviderManager"
plutil -lint "$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
test -f "$app/Contents/Resources/en.lproj/Localizable.strings"
test -f "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
if rg -a -n '(sk-[A-Za-z0-9_-]{20,}|Bearer [A-Za-z0-9_-]{20,})' "$app"; then
  echo "Potential secret found in app bundle" >&2
  exit 1
fi
echo "Packaging smoke test passed: $app"
