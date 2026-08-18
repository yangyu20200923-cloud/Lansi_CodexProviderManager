#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="$project_dir/dist/Codex Provider Manager.app"
dmg="$project_dir/dist/Lansi_CodexProviderManager-macos.dmg"
"$project_dir/scripts/build-dmg.sh" --replace
test -x "$app/Contents/MacOS/CodexProviderManager"
plutil -lint "$app/Contents/Info.plist"
test "$(plutil -extract CFBundleIconFile raw "$app/Contents/Info.plist")" = "LansiObserve.icns"
codesign --verify --deep --strict "$app"
test -f "$app/Contents/Resources/LansiObserve.icns"
test -f "$app/Contents/Resources/en.lproj/Localizable.strings"
test -f "$app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
if rg -a -n '(sk-[A-Za-z0-9_-]{20,}|Bearer [A-Za-z0-9_-]{20,})' "$app"; then
  echo "Potential secret found in app bundle" >&2
  exit 1
fi
test -f "$dmg"
test -f "$dmg.sha256"
hdiutil verify "$dmg"
(cd "$(dirname "$dmg")" && shasum -a 256 -c "$(basename "$dmg").sha256")
echo "Packaging smoke test passed: $app and $dmg"
