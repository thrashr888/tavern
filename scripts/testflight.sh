#!/usr/bin/env bash
# Archives the iPhone app with the party bundled in (scripts/party.sh: personal, never in git) and
# uploads it to App Store Connect for TestFlight. Signing and the upload use the Apple ID that Xcode
# is signed in with (Xcode > Settings > Accounts); the app record (dev.thrashr888.tavern.phone) must
# already exist in App Store Connect. The build number is the time, so each upload is new.
#   scripts/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Needs xcodegen: brew install xcodegen" >&2; exit 1; }

scripts/party.sh
xcodegen generate --spec iOS/project.yml --quiet

out=.build/testflight
build="$(date +%Y%m%d%H%M)"
rm -rf "$out" && mkdir -p "$out"
xcodebuild -project iOS/TavernPhone.xcodeproj -scheme TavernPhone -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$out/TavernPhone.xcarchive" \
  -derivedDataPath .build/ios-release-dd -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$build" -quiet archive

cat > "$out/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>5T4QSYSNP2</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/TavernPhone.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates
echo "Uploaded build $build. It shows in TestFlight once App Store Connect finishes processing."
