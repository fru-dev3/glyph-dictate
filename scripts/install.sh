#!/bin/zsh
# Build Glyph Jot from source and put it in /Applications.
# Needs Xcode 26 and XcodeGen (`brew install xcodegen`). Set DEVELOPMENT_TEAM to your Apple
# team ID to sign with it (macOS then keeps Glyph Jot's permissions across rebuilds); without it the
# build is signed to run on this Mac only, and macOS asks for the permissions again each build.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --quiet
sign=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-)
[[ -n ${DEVELOPMENT_TEAM:-} ]] && sign=(DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM -allowProvisioningUpdates)
xcodebuild -project Jot.xcodeproj -scheme JotMac -configuration Release -derivedDataPath build -quiet "${sign[@]}" build
pkill -x Jot 2>/dev/null || true # quits the app the normal way; it takes its dictation engine with it
sleep 1
rm -rf /Applications/Jot.app && cp -R build/Build/Products/Release/Jot.app /Applications/
open /Applications/Jot.app
echo "Glyph Jot is open. First run: Settings > General > Permissions."
