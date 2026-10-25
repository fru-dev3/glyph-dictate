#!/bin/zsh
# Build, sign with Developer ID, notarize and publish a release on GitHub: Glyph-Dictate-<version>.dmg,
# plus Glyph-Dictate.dmg and Jot.dmg for the stable links (releases/latest/download/...); the old
# jot.fru.dev site still points at Jot.dmg.
# Needs a "Developer ID Application" certificate in the keychain, an App Store Connect API key
# for notarization (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH), and the GitHub CLI signed in.
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} # xcodebuild needs Xcode, not the command line tools
: ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ${ASC_KEY_PATH:?set ASC_KEY_PATH}
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
[[ -n $identity ]] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
team=${identity##*\(}; team=${team%\)}
version=$(awk '/MARKETING_VERSION/{gsub(/"/,"",$2); print $2; exit}' project.yml)

echo "building Glyph Dictate $version"
xcodegen generate --quiet
xcodebuild -project Jot.xcodeproj -scheme Jot -configuration Release -derivedDataPath build -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build # no get-task-allow: notarization refuses it
app=build/Build/Products/Release/Jot.app
codesign --verify --strict --deep "$app"

echo "making the disk image"
rm -rf dist && mkdir -p dist/stage
cp -R "$app" dist/stage/ && ln -s /Applications dist/stage/Applications
dmg=dist/Glyph-Dictate-$version.dmg
hdiutil create -volname "Glyph Dictate $version" -srcfolder dist/stage -fs HFS+ -format UDZO -ov "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"

echo "notarizing (a few minutes)"
result=$(xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 20m)
echo "$result"
if ! grep -q "status: Accepted" <<<"$result"; then
  id=$(awk '/^ *id:/{print $2; exit}' <<<"$result")
  xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID"
  echo "notarization was not accepted (log above)"; exit 1
fi
xcrun stapler staple "$dmg"

echo "checking a downloaded copy passes Gatekeeper"
cp "$dmg" dist/check.dmg
xattr -w com.apple.quarantine "0081;00000000;Safari;" dist/check.dmg
spctl --assess --type open --context context:primary-signature -v dist/check.dmg
rm dist/check.dmg
cp "$dmg" dist/Jot.dmg; cp "$dmg" dist/Glyph-Dictate.dmg

notes=$(awk -v v="**$version**" 'index($0, "- " v) == 1 {sub(/^- /, ""); print; exit}' README.md)
if gh release view "v$version" >/dev/null 2>&1; then
  gh release upload "v$version" "$dmg" dist/Glyph-Dictate.dmg dist/Jot.dmg --clobber
else
  gh release create "v$version" "$dmg" dist/Glyph-Dictate.dmg dist/Jot.dmg --title "Glyph Dictate $version" --notes "${notes:-Glyph Dictate $version}"
fi
echo "released: https://github.com/fru-dev3/glyph-dictate/releases/tag/v$version"
