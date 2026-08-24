#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if ! swift build -c release --disable-index-store --disable-sandbox; then
  # Restricted environments may deny the dSYM step after linking succeeds.
  # The binary existence check below keeps the package build honest.
  echo "warning: release build finished with a non-zero exit; verifying the binary below"
fi
bin_dir="$(swift build -c release --show-bin-path --disable-sandbox)"
test -x "$bin_dir/CodexProviderManager" || { echo "error: release binary missing: $bin_dir/CodexProviderManager"; exit 1; }
app_dir="$project_dir/dist/Codex Provider Manager.app"
app_icon="$project_dir/Resources/LansiObserve.icns"
test -f "$app_icon"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexProviderManager" "$app_dir/Contents/MacOS/CodexProviderManager"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$app_icon" "$app_dir/Contents/Resources/LansiObserve.icns"
resource_bundle="$bin_dir/CodexProviderManager_CodexProviderManager.bundle"
if [[ -d "$resource_bundle" ]]; then cp -R "$resource_bundle" "$app_dir/Contents/Resources/"; fi
for language in en zh-Hans; do
  mkdir -p "$app_dir/Contents/Resources/$language.lproj"
  cp "$project_dir/Resources/$language.lproj/Localizable.strings" "$app_dir/Contents/Resources/$language.lproj/Localizable.strings"
done
printf 'APPL????' > "$app_dir/Contents/PkgInfo"
chmod 755 "$app_dir/Contents/MacOS/CodexProviderManager"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
