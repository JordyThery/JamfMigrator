#!/bin/zsh
# Jamf Migrator's release check (JTKit ROADMAP step 11). Claude runs it
# unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#
#   scripts/release-check.sh [--local-jtkit] [--tenants] [--stop-before-live]
#   scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|interrupt-live
#     (tests the check itself; never part of a release check)
#
# Tenants are roles on the local allow-list (never named here): jamf-test-a,
# the source, over the Jamf Platform API; jamf-test-b, the destination, over
# the Jamf Platform API and over its direct Jamf Pro connection.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Jamf Migrator"
APP_CODE="JM"
PROJECT="JamfMigrator.xcodeproj"
SCHEME="JamfMigrator Release Check"
UNIT_TESTS="JamfMigratorTests"
UI_TESTS="JamfMigratorUITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/JamfMigratorUITests/DemoSmokeUITests.swift"
SIGNIN_TEST="JamfMigratorTests/LiveSignInTests"
LIVE_TESTS=(
    "JamfMigratorTests/LiveMigrationTests/platformToPlatform()"
    "JamfMigratorTests/LiveMigrationTests/platformToDirect()"
)
CLEANUP_TEST="JamfMigratorTests/LiveCleanupTests"
ROLES=(jamf-test-a jamf-test-b)
# role:service:item, read from the Keychain service the allow-list names
CREDENTIALS=(
    "jamf-test-a:jamfPlatform:client-id"
    "jamf-test-a:jamfPlatform:client-secret"
    "jamf-test-b:jamfPlatform:client-id"
    "jamf-test-b:jamfPlatform:client-secret"
    "jamf-test-b:jamfPro:jamfpro-username"
    "jamf-test-b:jamfPro:jamfpro-password"
)
# No older test objects: the app never had tests that reached a tenant.
LEGACY_PREFIXES=""
DOMAIN="be.jordythery.jamfmigrator"
CONTAINER="$HOME/Library/Containers/$DOMAIN/Data"
# The app is sandboxed: its test host reaches only its own container, so the
# live folder (allow-list copy, ledger, results) lives there (JTKit 0.12.2).
TEST_HOST_CONTAINER="$DOMAIN"
# Everything the app saves: tenants.json (the saved tenants), settings.plist,
# journals/, backups/, exports/ and Run Reports/; and the retired log folder.
FINGERPRINT_PATHS=(
    "$CONTAINER/Library/Application Support/JamfMigrator"
    "$CONTAINER/Library/Logs/JamfMigrator"
)
# The tenants in use, demo mode, the type selection, the export switch and
# every saved mapping (hashes only, never the values).
FINGERPRINT_DEFAULTS=(
    "$DOMAIN sourceTenantID" "$DOMAIN destTenantID" "$DOMAIN demoMode"
    "$DOMAIN selectedTypeKeys" "$DOMAIN exportOnRun"
)
for key in ${(f)"$(defaults read "$DOMAIN" 2>/dev/null | sed -nE 's/^ *"?(mappings-[^" =]+)"? = .*/\1/p')"}; do
    [[ -n "$key" ]] && FINGERPRINT_DEFAULTS+=("$DOMAIN $key")
done
KEYCHAIN_PREFIXES=("JamfMigrator-tenant")

# Under tests the app refuses every request to a saved tenant and writes the
# attempt here; the live checks' last step fails the run if it isn't empty.
# A new run starts with no attempts.
rm -rf "$CONTAINER/tmp/JamfMigrator-under-test"

# The template comes from the JTKit under test: the local checkout with
# --local-jtkit, otherwise the published version this project resolves.
if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 0.12.2 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
