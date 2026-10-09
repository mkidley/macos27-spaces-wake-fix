#!/bin/bash
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo 'Run without sudo.' >&2; exit 1; }
if [[ -f "$HOME/Library/Application Support/SpacesKeeper/native-owner.json" ]]; then
    echo 'Use SpacesKeeper Settings to return to the previous LaunchAgent before rolling back its binary.' >&2; exit 1
fi
base="$HOME/Library/Application Support/SpacesWakeFix"
label=org.spaceswakefix.agent
domain="gui/$(id -u)"
[[ -x "$base/spaces-wake-fix.previous" ]] || { echo 'No previous helper saved.' >&2; exit 1; }
if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$label"
fi
/usr/bin/install -m 700 "$base/spaces-wake-fix.previous" "$base/spaces-wake-fix"
/bin/launchctl bootstrap "$domain" "$HOME/Library/LaunchAgents/$label.plist"
echo 'Previous helper restored. SpacesKeeper backup/settings are retained; macOS assignments are unchanged.'
