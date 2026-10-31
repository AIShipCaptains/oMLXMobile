#!/bin/zsh
# Build, archive, and upload oMLX Mobile to App Store Connect (TestFlight).
#
# Usage:
#   scripts/release.sh <TEAM_ID> <API_KEY_PATH> <API_KEY_ID> <API_ISSUER_ID>
#
# Prerequisites:
#   - Apple Developer Program membership (paid team)
#   - App record created in App Store Connect for bundle id ai.omlx.oMLXMobile
#   - App Store Connect API key (.p8) with App Manager role
#   - Xcode with iOS platform installed
#
# Optional env:
#   VERSION, BUILD   — override marketing version / build number
set -euo pipefail

TEAM_ID="${1:?usage: release.sh <TEAM_ID> <API_KEY_PATH> <API_KEY_ID> <API_ISSUER_ID>}"
API_KEY_PATH="${2:?missing API key path}"
API_KEY_ID="${3:?missing API key id}"
API_ISSUER_ID="${4:?missing API issuer id}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XB="${XCODEBUILD:-/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild}"
BUILD_DIR="$ROOT/build/release"
ARCHIVE="$BUILD_DIR/oMLXMobile.xcarchive"

VERSION="${VERSION:-}"
BUILD="${BUILD:-}"

# Generate the export options with the real team id
sed "s/__TEAM_ID__/$TEAM_ID/" "$ROOT/scripts/ExportOptions.plist.template" > "$BUILD_DIR/ExportOptions.plist" 2>/dev/null || {
  mkdir -p "$BUILD_DIR"
  sed "s/__TEAM_ID__/$TEAM_ID/" "$ROOT/scripts/ExportOptions.plist.template" > "$BUILD_DIR/ExportOptions.plist"
}

VERSION_FLAG=()
[[ -n "$VERSION" ]] && VERSION_FLAG=("MARKETING_VERSION=$VERSION")
BUILD_FLAG=()
[[ -n "$BUILD" ]] && BUILD_FLAG=("CURRENT_PROJECT_VERSION=$BUILD")

echo "==> Archiving"
"$XB" -project "$ROOT/oMLXMobile.xcodeproj" \
  -scheme oMLXMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$API_KEY_PATH" \
  -authenticationKeyID "$API_KEY_ID" \
  -authenticationKeyIssuerID "$API_ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  "${VERSION_FLAG[@]}" "${BUILD_FLAG[@]}" \
  archive

echo "==> Exporting & uploading to App Store Connect (TestFlight)"
"$XB" -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$API_KEY_PATH" \
  -authenticationKeyID "$API_KEY_ID" \
  -authenticationKeyIssuerID "$API_ISSUER_ID" \
  -exportPath "$BUILD_DIR"

echo "==> Done. Track processing at https://appstoreconnect.apple.com/apps"
echo "    TestFlight: builds appear after processing (5–30 min), then add testers."