#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
bash -n install.sh uninstall.sh rollback-helper.sh spaceskeeper tests/check.sh build-app.sh install-app.sh uninstall-app.sh package-release.sh
plutil -lint Native/Info.plist
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/spaces-wake-fix-tests.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$test_dir/modules" Sources/main.swift Sources/Assignments.swift -o "$test_dir/helper"
"$test_dir/helper" --self-test
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$test_dir/modules" Sources/Assignments.swift tests/AssignmentTests.swift -o "$test_dir/assignment-tests"
"$test_dir/assignment-tests"
sed -n '/^    display dialog /p' Sources/main.swift > "$test_dir/reminder.applescript"
osacompile -o "$test_dir/reminder.scpt" "$test_dir/reminder.applescript"
echo 'Shell syntax, Swift compilation and reminder AppleScript syntax passed. No agent installed or Dock restarted.'
