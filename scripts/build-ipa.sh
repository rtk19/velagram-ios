#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/configure.sh"
MODE="${1:-development}"
case "$MODE" in
  development|ad-hoc|app-store-connect|unsigned) ;;
  *) echo "Usage: $0 [development|ad-hoc|app-store-connect|unsigned]" >&2; exit 2 ;;
esac
OUTPUT="$ROOT/build/$MODE"
mkdir -p "$OUTPUT"
if [[ "$MODE" == unsigned ]]; then
  xcodebuild -project "$ROOT/Velagram.xcodeproj" -scheme Velagram -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$OUTPUT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  mkdir -p "$STAGING/Payload"
  cp -R "$OUTPUT/DerivedData/Build/Products/Release-iphoneos/Velagram.app" "$STAGING/Payload/"
  (cd "$STAGING" && /usr/bin/zip -qry "$OUTPUT/Velagram-unsigned.ipa" Payload)
  echo "Unsigned package: $OUTPUT/Velagram-unsigned.ipa — must be signed before installation."
else
  xcodebuild -project "$ROOT/Velagram.xcodeproj" -scheme Velagram -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$OUTPUT/Velagram.xcarchive" \
    -allowProvisioningUpdates archive
  METHOD="$MODE"
  [[ "$MODE" != development ]] || METHOD=debugging
  [[ "$MODE" != ad-hoc ]] || METHOD=release-testing
  cat > "$OUTPUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>$METHOD</string>
<key>teamID</key><string>A97K2SS8D9</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>export</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$OUTPUT/Velagram.xcarchive" \
    -exportPath "$OUTPUT" -exportOptionsPlist "$OUTPUT/ExportOptions.plist" -allowProvisioningUpdates
  echo "Signed IPA exported to $OUTPUT"
fi
