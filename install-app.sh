#!/bin/bash
set -euo pipefail
[[ $EUID -ne 0 ]] || { echo 'Run without sudo.' >&2; exit 1; }
cd -- "$(dirname -- "$0")"
./build-app.sh "$@"
destination="$HOME/Applications/SpacesKeeper.app"
# Do not replace a live app. Quit through its menu so its helper stops cleanly.
if pgrep -u "$(id -u)" -x SpacesKeeper >/dev/null; then
    echo 'Quit SpacesKeeper, then rerun the installer.' >&2; exit 1
fi
mkdir -p "$HOME/Applications"
if [[ -e "$destination" ]]; then
    backup="$HOME/Applications/SpacesKeeper.previous.app"
    [[ ! -e "$backup" ]] || { echo "Move or remove $backup before updating." >&2; exit 1; }
    mv "$destination" "$backup"
fi
ditto .build/native/SpacesKeeper.app "$destination"
open "$destination"
echo 'Opened SpacesKeeper. The current LaunchAgent remains active until Start SpacesKeeper Repairs succeeds.'
