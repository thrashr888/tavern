#!/usr/bin/env bash
# Retakes the README screenshots from the demo party (scripts/demo.sh) into docs/screenshots.
# Needs Screen Recording permission for the terminal running it. Clicks nothing, but the card shots
# bring the demo app forward for a few seconds (web views don't draw while hidden).
set -euo pipefail
cd "$(dirname "$0")/.."
out=docs/screenshots
mkdir -p "$out"
scripts/demo.sh >/dev/null 2>&1 &
demo=$!
trap 'pkill -f "demo/Tavern.app/Contents/MacOS/Tavern" || true; kill $demo 2>/dev/null || true; pkill -f "docs/demo/runtime.mjs" || true; lsof -ti tcp:19613 | xargs kill 2>/dev/null || true' EXIT
until [ -x .build/demo/Tavern.app/Contents/MacOS/Tavern ] && pgrep -f "demo/Tavern.app/Contents/MacOS/Tavern" >/dev/null; do sleep 1; done
frame='NSWindow Frame SwiftUI.WindowGroup<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<TavernApp.RootView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<TavernApp.AppModel>>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<TavernApp.ModifierWatcher>>>, SwiftUI._AppearanceActionModifier>, SwiftUI._FlexFrameLayout>>-1-AppWindow-1'
shot() { # page file [mail thread] [--front]
  pkill -f "demo/Tavern.app/Contents/MacOS/Tavern" || true
  sleep 1
  defaults write dev.thrashr888.tavern.demo "$frame" "56 40 1400 880 0 0 1512 949 "
  TAVERN_HOME="$PWD/.build/demo-home" TAVERN_PAGE="$1" TAVERN_MAIL_THREAD="${3:-}" \
    .build/demo/Tavern.app/Contents/MacOS/Tavern -ApplePersistenceIgnoreState YES >/dev/null 2>&1 & disown
  local pid=$! wid=""
  for _ in $(seq 1 20); do wid=$(swift scripts/window-id.swift $pid 2>/dev/null) && break; sleep 1; done
  sleep "${SHOT_WAIT:-7}"
  swift scripts/capture.swift "$pid" "$wid" "$out/$2" ${4:-}
  sips --resampleWidth 1600 "$out/$2" >/dev/null
  echo "$out/$2"
}
# Agent pages first: opening them stores the agents' messages the Dashboard charts.
shot agent:scout agent.png
shot agent:forge approval.png
shot mail:all mail.png t-pricing
# Ivy's cider cards, then the same agent asked about Home (a fresh thread, so only that shows).
SHOT_WAIT=14 shot agent:ivy cards.png "" --front
home="$PWD/.build/demo-home"
lsof -ti tcp:19613 | xargs kill 2>/dev/null || true
sqlite3 "$home/tavern.sqlite" "DELETE FROM events WHERE thread_key = 'pi:ivy'; DELETE FROM cursors WHERE source = 'pi:ivy';"
TAVERN_DURABLE_RUNTIME="$PWD/docs/demo/runtime.mjs" TAVERN_DURABLE_PORT=19613 TAVERN_DURABLE_HEARTBEAT_MINUTES=0 \
  TAVERN_DURABLE_REQUESTS="$home/ivy-home-requests.json" AGENT_CWD="$home/ivy" DEMO_NAME=ivy-home \
  DEMO_TRANSCRIPT="$home/ivy-home.json" node bridge/tavern-durable/host.mjs 2>/dev/null &
sleep 2
SHOT_WAIT=14 shot agent:ivy home.png "" --front
shot dashboard dashboard.png
