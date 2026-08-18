#!/bin/bash
set -euo pipefail

target_dir="$HOME/Applications"
trash_dir="$HOME/.Trash"
purge=false

usage() {
  cat <<'EOF'
Usage: uninstall-app.sh [--target-dir PATH] [--trash-dir PATH] [--purge]

Moves Codex Provider Manager.app to Trash by default. --purge permanently removes
only that app bundle. Neither mode changes Codex homes, profiles, sessions, Skills,
MCP, plugins, backups, or credentials.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir) target_dir="$2"; shift 2 ;;
    --trash-dir) trash_dir="$2"; shift 2 ;;
    --purge) purge=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

installed_app="$target_dir/Codex Provider Manager.app"
if [[ ! -e "$installed_app" ]]; then
  echo "Not installed: $installed_app"
  exit 0
fi

if "$purge"; then
  rm -rf -- "$installed_app"
  echo "Removed: $installed_app"
else
  mkdir -p "$trash_dir"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  trashed_app="$trash_dir/Codex Provider Manager $timestamp.app"
  mv "$installed_app" "$trashed_app"
  echo "Moved to Trash: $trashed_app"
fi

echo "Codex homes, profiles, sessions, Skills, MCP, plugins, backups, and credentials were not changed."
