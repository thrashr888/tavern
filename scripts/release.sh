#!/usr/bin/env bash
# Cuts a Tavern release from this Mac (Apple silicon): check -> build -> sign ->
# notarize -> zip -> tag -> GitHub release. Builds never run in GitHub Actions.
#   RELEASE_APPROVED=yes NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh 1.0.0
# Credentials stay in the keychain. Publishing the release triggers .github/workflows/homebrew.yml,
# which updates the cask in thrashr888/homebrew-tap (needs the HOMEBREW_TAP_TOKEN secret).
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh <version>}"
tag="v$version"

# Releases need a person's decision. Agents never set this themselves.
[ "${RELEASE_APPROVED:-}" = "yes" ] || {
  echo "release: refusing to run without human approval; rerun with RELEASE_APPROVED=yes." >&2; exit 1; }
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile}"
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "$identity" ] || { echo "No Developer ID Application identity" >&2; exit 1; }

# Fail before the build, not after it.
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "Not on main." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Working tree not clean." >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not at origin/main." >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "Tag $tag already exists." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "Notary profile '$NOTARY_PROFILE' not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in." >&2; exit 1; }

out="${BUILD_DIR:-.build/dist}"
rm -rf "$out" && mkdir -p "$out"
app="$out/Tavern.app"
zip="$out/Tavern-$version-macos-arm64.zip"
scripts/check.sh
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

# The build must not have touched tracked files.
[ -z "$(git status --porcelain)" ] || { echo "Build dirtied the tree; not tagging." >&2; git status --porcelain >&2; exit 1; }
git tag "$tag"
git push origin "$tag"
gh release create "$tag" "$zip" "$out/SHA256SUMS" --title "Tavern $tag" --generate-notes
echo "Released $tag: https://github.com/thrashr888/tavern/releases/tag/$tag"
