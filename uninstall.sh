#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'This project requires macOS.' >&2; exit 1; }
[[ $EUID -ne 0 ]] || { echo 'Run as the installing user, without sudo.' >&2; exit 1; }
if [[ -f "$HOME/Library/Application Support/SpacesKeeper/native-owner.json" ]]; then
    exec "$HOME/Applications/SpacesKeeper.app/Contents/Resources/uninstall-app.sh"
fi
label=org.spaceswakefix.agent
domain="gui/$(id -u)"
base="$HOME/Library/Application Support/SpacesWakeFix"
if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$domain/$label" || {
        echo 'Could not stop the helper; no files removed. Retry from your desktop session.' >&2; exit 1;
    }
fi
/bin/rm -f -- "$HOME/Library/LaunchAgents/$label.plist"
# This directory is reserved exclusively for the installation and its state.
/bin/rm -rf -- "$base" "$HOME/Library/Application Support/SpacesKeeper"
echo 'Spaces Wake Fix and SpacesKeeper saved data removed. Your downloaded project and macOS-managed logs remain.'
