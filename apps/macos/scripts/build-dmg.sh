#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_path="$project_dir/dist/Lansi_CodexProviderManager-macos.dmg"
replace=false

for argument in "$@"; do
  case "$argument" in
    --replace) replace=true ;;
    *) output_path="$argument" ;;
  esac
done

if [[ -e "$output_path" && "$replace" != true ]]; then
  echo "DMG already exists. Re-run with --replace to rebuild: $output_path" >&2
  exit 1
fi

"$project_dir/scripts/build-app.sh"
app_path="$project_dir/dist/Codex Provider Manager.app"
test -d "$app_path"

staging_root="$(mktemp -d "${TMPDIR%/}/lansi-dmg.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
mkdir -p "$(dirname "$output_path")"
cp -R "$app_path" "$staging_root/Codex Provider Manager.app"

hdiutil create \
  -volname "Lansi Codex Provider Manager" \
  -srcfolder "$staging_root" \
  -format UDZO \
  -ov \
  "$output_path"
hdiutil verify "$output_path"
shasum -a 256 "$output_path" > "$output_path.sha256"
echo "$output_path"
echo "$output_path.sha256"
