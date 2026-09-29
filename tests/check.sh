#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
bash -n install.sh uninstall.sh tests/check.sh
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/spaces-wake-fix-tests.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$test_dir/modules" Sources/main.swift -o "$test_dir/helper"
"$test_dir/helper" --self-test
sed -n '/^    display dialog /p' Sources/main.swift > "$test_dir/reminder.applescript"
osacompile -o "$test_dir/reminder.scpt" "$test_dir/reminder.applescript"
echo 'Shell syntax, Swift compilation and reminder AppleScript syntax passed. No agent installed or Dock restarted.'
