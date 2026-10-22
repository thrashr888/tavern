#!/usr/bin/env bash
# Builds a release Tavern.app and installs it in ~/Applications, signed for this Mac only.
# scripts/release.sh uses it with BUNDLE_ID, VERSION and TAVERN_APP set.
#   scripts/bundle.sh            # build, install, relaunch
#   NO_LAUNCH=1 scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release -j "${JOBS:-4}"
app="${TAVERN_APP:-$HOME/Applications/Tavern.app}"
bin=.build/release
rm -rf "$app.new"
mkdir -p "$app.new/Contents/MacOS" "$app.new/Contents/Resources"
cp "$bin/Tavern" "$app.new/Contents/MacOS/Tavern"
cp -R "$bin/Tavern_TavernApp.bundle" "$app.new/Contents/Resources/"
# The icon Finder and the Dock show while Tavern isn't running (the app sets it again at launch).
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size Sources/TavernApp/Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Sources/TavernApp/Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app.new/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"
cat > "$app.new/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID:-dev.thrashr888.tavern.dev}</string>
<key>CFBundleName</key><string>Tavern</string>
<key>CFBundleExecutable</key><string>Tavern</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-$(git describe --always --dirty)}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSEnvironment</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
</dict></plist>
EOF
# A stable identity keeps keychain grants (Gmail token) across rebuilds; ad-hoc signing changes
# the code hash every build, so macOS asks again each time.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign -s "${identity:--}" --force "$app.new"
[ -n "${NO_LAUNCH:-}" ] || pkill -f 'Tavern.app/Contents/MacOS/Tavern' || true
rm -rf "$app" && mv "$app.new" "$app"
[ -n "${NO_LAUNCH:-}" ] || { sleep 1; open "$app"; }
echo "installed $app"
