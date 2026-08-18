#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$project_dir/dist/Codex Provider Manager.app"
target_dir="$HOME/Applications"
replace=false
launch=false

usage() {
  cat <<'EOF'
Usage: install-app.sh [--source PATH] [--target-dir PATH] [--replace] [--launch]

Installs the built Codex Provider Manager.app into the current user's Applications folder.
The script only replaces the named application when --replace is supplied.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_app="$2"; shift 2 ;;
    --target-dir) target_dir="$2"; shift 2 ;;
    --replace) replace=true; shift ;;
    --launch) launch=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

destination="$target_dir/Codex Provider Manager.app"
[[ -d "$source_app" ]] || { echo "App bundle not found: $source_app" >&2; exit 1; }
[[ -x "$source_app/Contents/MacOS/CodexProviderManager" ]] || { echo "App executable is missing." >&2; exit 1; }
[[ -f "$source_app/Contents/Info.plist" ]] || { echo "App metadata is missing." >&2; exit 1; }
[[ "$source_app" != "$destination" ]] || { echo "Source and destination are the same app bundle." >&2; exit 1; }

if [[ -e "$destination" ]]; then
  "$replace" || { echo "Already installed: $destination (pass --replace to update it)." >&2; exit 1; }
  rm -rf -- "$destination"
fi

mkdir -p "$target_dir"
ditto "$source_app" "$destination"
codesign --verify --deep --strict "$destination"
echo "Installed: $destination"
echo "Codex homes, profiles, sessions, Skills, MCP, and plugins were not changed."

if "$launch"; then
  open -n "$destination"
fi
