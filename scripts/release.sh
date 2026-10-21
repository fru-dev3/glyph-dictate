#!/bin/zsh
# Build, sign with Developer ID, notarize and publish a release on GitHub: Jot-<version>.dmg,
# and Jot.dmg for the stable link (releases/latest/download/Jot.dmg) the site points to.
# Needs a "Developer ID Application" certificate in the keychain, an App Store Connect API key
# for notarization (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), and the GitHub CLI signed in.
set -euo pipefail
cd "${0:A:h}/.."
: ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ${ASC_KEY_PATH:?set ASC_KEY_PATH}
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
[[ -n $identity ]] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
team=${identity##*\(}; team=${team%\)}
version=$(awk '/MARKETING_VERSION/{gsub(/"/,"",$2); print $2; exit}' project.yml)

echo "building Jot $version"
xcodegen generate --quiet
xcodebuild -project Jot.xcodeproj -scheme Jot -configuration Release -derivedDataPath build -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp build
app=build/Build/Products/Release/Jot.app
codesign --verify --strict --deep "$app"

echo "making the disk image"
rm -rf dist && mkdir -p dist/stage
cp -R "$app" dist/stage/ && ln -s /Applications dist/stage/Applications
dmg=dist/Jot-$version.dmg
hdiutil create -volname "Jot $version" -srcfolder dist/stage -fs HFS+ -format UDZO -ov "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"

echo "notarizing (a few minutes)"
xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 20m
xcrun stapler staple "$dmg"

echo "checking a downloaded copy passes Gatekeeper"
cp "$dmg" dist/check.dmg
xattr -w com.apple.quarantine "0081;00000000;Safari;" dist/check.dmg
spctl --assess --type open --context context:primary-signature -v dist/check.dmg
rm dist/check.dmg
cp "$dmg" dist/Jot.dmg

notes=$(awk -v v="**$version**" 'index($0, "- " v) == 1 {sub(/^- /, ""); print; exit}' README.md)
if gh release view "v$version" >/dev/null 2>&1; then
  gh release upload "v$version" "$dmg" dist/Jot.dmg --clobber
else
  gh release create "v$version" "$dmg" dist/Jot.dmg --title "Jot $version" --notes "${notes:-Jot $version}"
fi
echo "released: https://github.com/fru-dev3/jot/releases/tag/v$version"
