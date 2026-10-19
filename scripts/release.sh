#!/usr/bin/env bash
# Builds, signs with Developer ID, notarizes and zips Tavern for a GitHub release (Apple silicon).
#   NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh 1.0.0
# Publishing (tag, release, Homebrew cask) is separate. Credentials stay in the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh <version>}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile}"
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$identity" ] || { echo "No Developer ID Application identity" >&2; exit 1; }
out="${BUILD_DIR:-.build/dist}"
rm -rf "$out" && mkdir -p "$out"
app="$out/Tavern.app"
zip="$out/Tavern-$version-macos-arm64.zip"
swift test -j "${JOBS:-4}"
TAVERN_APP="$app" BUNDLE_ID=dev.thrashr888.tavern VERSION="$version" NO_LAUNCH=1 SIGN_IDENTITY="$identity" scripts/bundle.sh
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
# Re-zip so the download carries the stapled ticket.
rm -f "$zip" && ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
(cd "$out" && shasum -a 256 "$(basename "$zip")" | tee SHA256SUMS)
