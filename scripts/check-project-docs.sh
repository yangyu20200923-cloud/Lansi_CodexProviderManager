#!/usr/bin/env bash
set -euo pipefail

for file in README.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md CHANGELOG.md LICENSE docs/development/repository-layout.md; do
  test -s "$file" || exit 1
done
rg -q 'Lansi_CodexProviderManager' README.md
rg -q '兰司观察 Codex_Provider 切换器' README.md
rg -q 'apps/macos' README.md
rg -q 'apps/windows' README.md
rg -q 'not affiliated with or endorsed by OpenAI' README.md
rg -q '本地跨平台' README.md
rg -q '每个测试都必须使用' CONTRIBUTING.md
rg -q '私下报告' SECURITY.md
