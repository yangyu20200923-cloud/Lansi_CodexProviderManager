#!/usr/bin/env bash
set -euo pipefail

test -f apps/macos/Package.swift
test -f apps/windows/switch_provider.py
test -f apps/windows/Test-Switcher.ps1
test ! -e CodexProviderManager
test ! -e CodexProviderSwitcherWindows
