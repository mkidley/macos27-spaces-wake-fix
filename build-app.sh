#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
umask 077
build="$PWD/.build/native"
app="$build/SpacesKeeper.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build/modules"
architectures="$(uname -m)"
if [[ ${1:-} == --universal ]]; then architectures='arm64 x86_64';
elif [[ $# -gt 0 ]]; then echo 'Usage: ./build-app.sh [--universal]' >&2; exit 1; fi
for architecture in $architectures; do
    xcrun swiftc -swift-version 5 -warnings-as-errors -O -target "$architecture-apple-macos13.0" -module-cache-path "$build/modules" Sources/Assignments.swift Native/SpacesKeeperApp.swift -o "$build/app-$architecture"
    xcrun swiftc -swift-version 5 -warnings-as-errors -O -target "$architecture-apple-macos13.0" -module-cache-path "$build/modules" Sources/main.swift Sources/Assignments.swift -o "$build/helper-$architecture"
done
if [[ ${1:-} == --universal ]]; then
    xcrun lipo -create "$build/app-arm64" "$build/app-x86_64" -output "$app/Contents/MacOS/SpacesKeeper"
    xcrun lipo -create "$build/helper-arm64" "$build/helper-x86_64" -output "$app/Contents/Resources/spaces-wake-fix"
else
    cp "$build/app-$(uname -m)" "$app/Contents/MacOS/SpacesKeeper"
    cp "$build/helper-$(uname -m)" "$app/Contents/Resources/spaces-wake-fix"
fi
xcrun swiftc -module-cache-path "$build/modules" Native/MakeIcon.swift -o "$build/make-icon"
"$build/make-icon" "$build/SpacesKeeper.iconset"
iconutil -c icns "$build/SpacesKeeper.iconset" -o "$app/Contents/Resources/SpacesKeeper.icns"
cp Native/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp uninstall-app.sh "$app/Contents/Resources/uninstall-app.sh"
chmod 755 "$app/Contents/Resources/uninstall-app.sh"
chmod 755 "$app/Contents/MacOS/SpacesKeeper" "$app/Contents/Resources/spaces-wake-fix"
signing=(--force --sign "${SPACESKEEPER_SIGN_IDENTITY:--}")
if [[ -n ${SPACESKEEPER_SIGN_IDENTITY:-} ]]; then signing+=(--options runtime --timestamp); fi
codesign "${signing[@]}" "$app/Contents/Resources/spaces-wake-fix"
codesign "${signing[@]}" "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/SpacesKeeper" --check
printf 'Built %s\n' "$app"
