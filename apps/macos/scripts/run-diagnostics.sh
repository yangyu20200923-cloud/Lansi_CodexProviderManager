#!/bin/bash
set -euo pipefail

codex_home="${CODEX_HOME:-$HOME/.codex}"
config="$codex_home/config.toml"
db="$codex_home/state_5.sqlite"
echo "Codex Provider Manager diagnostics"
echo "CODEX_HOME: ~/.codex (redacted)"
if [[ -f "$config" ]]; then
  sed -nE 's/^(model_provider|model|review_model|wire_api)[[:space:]]*=.*/\1 = <redacted-value>/p' "$config"
else
  echo "config.toml: missing"
fi
if [[ -f "$db" ]] && command -v sqlite3 >/dev/null; then
  echo "history_count: $(sqlite3 -readonly "$db" 'SELECT COUNT(*) FROM threads;' 2>/dev/null || echo unavailable)"
else
  echo "state_5.sqlite: missing or unreadable"
fi
for item in skills plugins mcp; do
  [[ -e "$codex_home/$item" ]] && echo "$item: present" || echo "$item: not detected"
done
