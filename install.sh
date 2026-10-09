#!/bin/bash
set -euo pipefail
umask 077
[[ "$(uname -s)" == Darwin ]] || { echo 'This project requires macOS.' >&2; exit 1; }
[[ $EUID -ne 0 ]] || { echo 'Run as your logged-in user, without sudo.' >&2; exit 1; }
if [[ -f "$HOME/Library/Application Support/SpacesKeeper/native-owner.json" ]]; then
    echo 'SpacesKeeper manages repairs now. Use install-app.sh to update the app, or its Settings to return to the old agent.' >&2
    exit 1
fi
delay=4
reminder=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-reminder) reminder=false; shift ;;
        --delay) [[ $# -ge 2 ]] || { echo '--delay needs seconds' >&2; exit 1; }; delay=$2; shift 2 ;;
        --help) echo 'Usage: ./install.sh [--no-reminder] [--delay SECONDS (1–60)]'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ $delay =~ ^[0-9]+([.][0-9]+)?$ ]] && /usr/bin/awk "BEGIN {exit !($delay >= 1 && $delay <= 60)}" || {
    echo 'Delay must be a number from 1 to 60.' >&2; exit 1;
}
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
label=org.spaceswakefix.agent
base="$HOME/Library/Application Support/SpacesWakeFix"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
/bin/launchctl print "$domain" >/dev/null 2>&1 || { echo 'Run from a logged-in desktop session.' >&2; exit 1; }
/usr/bin/xcrun --find swiftc >/dev/null 2>&1 || {
    echo 'Install Apple Command Line Tools with: xcode-select --install, then retry.' >&2; exit 1;
}
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/spaces-wake-fix.XXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
echo 'Compiling the local wake helper…'
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$build_dir/modules" -O "$source_dir/Sources/main.swift" "$source_dir/Sources/Assignments.swift" -o "$build_dir/spaces-wake-fix"
# Compile and validate before stopping any existing installation.
if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$label"
fi
/bin/mkdir -p "$base" "$HOME/Library/LaunchAgents"
/bin/chmod 700 "$base"
if [[ -x "$base/spaces-wake-fix" ]]; then
    /usr/bin/install -m 700 "$base/spaces-wake-fix" "$base/spaces-wake-fix.previous"
fi
/usr/bin/install -m 700 "$build_dir/spaces-wake-fix" "$base/spaces-wake-fix"
/usr/bin/install -m 700 "$source_dir/spaceskeeper" "$base/spaceskeeper"
/usr/bin/install -m 700 "$source_dir/rollback-helper.sh" "$base/rollback-helper.sh"
/usr/bin/install -m 700 "$source_dir/uninstall.sh" "$base/uninstall.sh"
"$base/spaces-wake-fix" --configure "$delay" "$reminder"
new_plist="$build_dir/agent.plist"
/usr/bin/plutil -create xml1 "$new_plist"
/usr/bin/plutil -insert Label -string "$label" "$new_plist"
/usr/bin/plutil -insert ProgramArguments -array "$new_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$base/spaces-wake-fix" "$new_plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$new_plist"
/usr/bin/plutil -insert KeepAlive -bool true "$new_plist"
/usr/bin/plutil -insert ThrottleInterval -integer 30 "$new_plist"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$new_plist"
/usr/bin/plutil -lint "$new_plist"
/usr/bin/install -m 600 "$new_plist" "$plist"
if ! /bin/launchctl bootstrap "$domain" "$plist"; then
    echo "Could not start the agent. Files remain for diagnosis; rerun installer or ./uninstall.sh." >&2
    exit 1
fi
echo "Installed. Dock will restart $delay seconds after the desktop is ready and wake/display changes have settled. Monthly reminder: $reminder."
echo 'Uninstall: "$HOME/Library/Application Support/SpacesWakeFix/uninstall.sh"'
