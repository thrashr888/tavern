#!/usr/bin/env bash
# Retakes the README screenshots from the demo party (scripts/demo.sh) into docs/screenshots.
# Needs Screen Recording permission for the terminal running it. Clicks nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
out=docs/screenshots
mkdir -p "$out"
scripts/demo.sh >/dev/null 2>&1 &
demo=$!
trap 'pkill -f "demo/Tavern.app/Contents/MacOS/Tavern" || true; kill $demo 2>/dev/null || true; pkill -f "docs/demo/runtime.mjs" || true' EXIT
until [ -x .build/demo/Tavern.app/Contents/MacOS/Tavern ] && pgrep -f "demo/Tavern.app/Contents/MacOS/Tavern" >/dev/null; do sleep 1; done
frame='NSWindow Frame SwiftUI.WindowGroup<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<TavernApp.RootView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<TavernApp.AppModel>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<TavernApp.ModifierWatcher>>>, SwiftUI._AppearanceActionModifier>, SwiftUI._FlexFrameLayout>>-1-AppWindow-1'
shot() { # page file [mail thread]
  pkill -f "demo/Tavern.app/Contents/MacOS/Tavern" || true
  sleep 1
  defaults write dev.thrashr888.tavern.demo "$frame" "56 40 1400 880 0 0 1512 949 "
  TAVERN_HOME="$PWD/.build/demo-home" TAVERN_PAGE="$1" TAVERN_MAIL_THREAD="${3:-}" \
    .build/demo/Tavern.app/Contents/MacOS/Tavern -ApplePersistenceIgnoreState YES >/dev/null 2>&1 & disown
  local pid=$! wid=""
  for _ in $(seq 1 20); do wid=$(swift scripts/window-id.swift $pid 2>/dev/null) && break; sleep 1; done
  sleep 7
  screencapture -x -o -l"$wid" "$out/$2"
  sips --resampleWidth 1600 "$out/$2" >/dev/null
  echo "$out/$2"
}
# Agent pages first: opening them stores the agents' messages the Dashboard charts.
shot agent:scout agent.png
shot agent:forge approval.png
shot mail:all mail.png t-pricing
shot dashboard dashboard.png
