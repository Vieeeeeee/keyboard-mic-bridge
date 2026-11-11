#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /private/tmp/keyboard-mic-bridge-test.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -warnings-as-errors -module-cache-path "$test_dir/module-cache" \
  "$project_dir/src/KeyboardMicBridge.swift" -o "$test_dir/KeyboardMicBridge"
"$test_dir/KeyboardMicBridge" --self-test
