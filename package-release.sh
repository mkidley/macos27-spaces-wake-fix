#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
./build-app.sh --universal
archive="$PWD/.build/SpacesKeeper-0.2.0-universal.zip"
ditto -c -k --keepParent .build/native/SpacesKeeper.app "$archive"
printf 'Created %s\n' "$archive"
if [[ -z ${SPACESKEEPER_SIGN_IDENTITY:-} ]]; then
    echo 'Local ad-hoc signature only. Developer ID signing and notarization are still required for a normal public download experience.'
fi
