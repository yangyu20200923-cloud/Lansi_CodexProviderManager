#!/usr/bin/env bash
set -euo pipefail
workflow=.github/workflows/ci.yml
test -s "$workflow" || exit 1
rg -q 'macos-latest' "$workflow"
rg -q 'windows-latest' "$workflow"
rg -q 'swift test --disable-index-store' "$workflow"
rg -q 'swift run --disable-index-store IntegrationProbe' "$workflow"
rg -q 'Test-Switcher.ps1' "$workflow"
rg -q 'spec/tests/validate_profiles.py' "$workflow"
rg -q 'spec/tests/validate_safety_fixtures.py' "$workflow"
rg -q 'check-repository-layout.sh' "$workflow"
rg -q 'check-project-docs.sh' "$workflow"
