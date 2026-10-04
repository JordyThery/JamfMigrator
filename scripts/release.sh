#!/bin/zsh
#
# Builds, signs, notarizes and staples a distributable Jamf Migrator.
#
# One-time setup — store notarization credentials in the keychain:
#   xcrun notarytool store-credentials "JamfMigrator-notary" \
#       --apple-id you@example.com --team-id K3LQ9NPBMG \
#       --password <app-specific password from appleid.apple.com>
#
# Usage: scripts/release.sh [notary-keychain-profile]
#   With no profile argument, the build is signed but not notarized.

set -euo pipefail

cd "$(dirname "$0")/.."
profile="${1:-}"
build_dir="build/release"
archive="$build_dir/JamfMigrator.xcarchive"
export_dir="$build_dir/export"
app="$export_dir/Jamf Migrator.app"

rm -rf "$build_dir"
mkdir -p "$build_dir"

echo "==> Archiving (Release)…"
xcodebuild archive \
    -project JamfMigrator.xcodeproj \
    -scheme JamfMigrator \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$archive" \
    | grep -E "error|warning: .*(deprecat|sign)|ARCHIVE" || true

echo "==> Exporting with Developer ID…"
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist scripts/ExportOptions.plist \
    -allowProvisioningUpdates \
    | grep -E "error|EXPORT" || true

echo "==> Verifying the signature…"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements - "$app" | head -20

version=$(defaults read "$PWD/$app/Contents/Info.plist" CFBundleShortVersionString)
zip="$build_dir/JamfMigrator-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

if [[ -n "$profile" ]]; then
    echo "==> Notarizing ($profile)…"
    xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
    echo "==> Stapling…"
    xcrun stapler staple "$app"
    # re-zip with the stapled ticket inside
    rm "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    echo "==> Gatekeeper assessment…"
    spctl --assess --type execute --verbose=2 "$app"
else
    echo "==> Skipping notarization (no keychain profile given)."
    echo "    Run: scripts/release.sh JamfMigrator-notary"
fi

echo "==> Done: $zip"
