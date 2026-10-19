#!/usr/bin/env bash
# Runs Tavern with a made-up party (docs/demo) for screenshots: two fake Pi agents, sample mail,
# nothing from your real setup. Its own data folder, bundle id and ports; Ctrl-C stops it.
#   scripts/demo.sh            # build, seed, start the fake agents, open the demo app
set -euo pipefail
cd "$(dirname "$0")/.."
home="${TAVERN_HOME:-$PWD/.build/demo-home}"
rm -rf "$home" && mkdir -p "$home"
cp docs/demo/roster.json "$home/"
python3 docs/demo/seed-mail.py "$home/tavern.sqlite"
app="$PWD/.build/demo/Tavern.app"
TAVERN_APP="$app" BUNDLE_ID=dev.thrashr888.tavern.demo VERSION=demo NO_LAUNCH=1 scripts/bundle.sh >/dev/null
host() { # name port transcript [approval]
  TAVERN_DURABLE_RUNTIME="$PWD/docs/demo/runtime.mjs" TAVERN_DURABLE_PORT="$2" TAVERN_DURABLE_HEARTBEAT_MINUTES=0 \
    TAVERN_DURABLE_REQUESTS="$home/$1-requests.json" AGENT_CWD="$home/$1" DEMO_NAME="$1" \
    DEMO_TRANSCRIPT="$PWD/docs/demo/$3" DEMO_APPROVAL="${4:-}" node bridge/tavern-durable/host.mjs 2>/dev/null &
}
mkdir -p "$home/scout" "$home/forge"
host scout 19611 scout.json
host forge 19612 forge.json "docker rm -v staging-old-db"
trap 'kill $(jobs -p) 2>/dev/null' EXIT
sleep 1
TAVERN_HOME="$home" TAVERN_PAGE="${TAVERN_PAGE:-dashboard}" "$app/Contents/MacOS/Tavern" &
wait
