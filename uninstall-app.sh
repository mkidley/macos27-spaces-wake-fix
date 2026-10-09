#!/bin/bash
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo 'Run without sudo.' >&2; exit 1; }
app="$HOME/Applications/SpacesKeeper.app"
label=org.spaceswakefix.agent
domain="gui/$(id -u)"
if [[ -x "$app/Contents/MacOS/SpacesKeeper" ]]; then
    "$app/Contents/MacOS/SpacesKeeper" --unregister-login
fi
if pgrep -u "$(id -u)" -x SpacesKeeper >/dev/null; then
    pkill -TERM -u "$(id -u)" -x SpacesKeeper
    for attempt in {1..30}; do
        pgrep -u "$(id -u)" -x SpacesKeeper >/dev/null || break
        sleep 0.2
    done
    if pgrep -u "$(id -u)" -x SpacesKeeper >/dev/null; then
        echo 'SpacesKeeper did not quit. No files removed; quit the app and retry.' >&2; exit 1
    fi
fi
if launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$label"
fi
if pgrep -u "$(id -u)" -x spaces-wake-fix >/dev/null; then
    echo 'A repair helper is still running. No files removed; stop it and retry.' >&2; exit 1
fi
rm -f -- "$HOME/Library/LaunchAgents/$label.plist"
rm -rf -- "$HOME/Library/Application Support/SpacesWakeFix" "$HOME/Library/Application Support/SpacesKeeper" "$app"
echo 'SpacesKeeper and its saved data removed. Actual macOS application assignments were not changed.'
