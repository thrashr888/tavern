#!/usr/bin/env bash
# Builds the iPhone app (iOS/) and runs it in the iOS Simulator. The Simulator shares this Mac's
# loopback, so an agent host here is at 127.0.0.1.
#   scripts/phone.sh                                   # agents from the app's own list
#   TAVERN_AGENTS="Flint=127.0.0.1:19011" TAVERN_OPEN=flint scripts/phone.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Needs xcodegen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec iOS/project.yml --quiet
device="${SIMULATOR:-$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/ {print $2; exit}')}"
[ -n "$device" ] || { echo "No iPhone simulator; install one with xcodebuild -downloadPlatform iOS" >&2; exit 1; }
xcrun simctl boot "$device" 2>/dev/null || true
xcodebuild -project iOS/TavernPhone.xcodeproj -scheme TavernPhone -destination "id=$device" \
  -derivedDataPath .build/ios-dd -quiet build
xcrun simctl install "$device" .build/ios-dd/Build/Products/Debug-iphonesimulator/TavernPhone.app
SIMCTL_CHILD_TAVERN_AGENTS="${TAVERN_AGENTS:-}" SIMCTL_CHILD_TAVERN_OPEN="${TAVERN_OPEN:-}" \
  xcrun simctl launch --terminate-running-process "$device" dev.thrashr888.tavern.phone
# Newer Xcodes ship no Simulator app; the device still runs and screenshots work.
simulator="$(xcode-select -p)/Applications/Simulator.app"
[ -d "$simulator" ] && open "$simulator" || echo "Running on $device (xcrun simctl io $device screenshot shot.png)"
