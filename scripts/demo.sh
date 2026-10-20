#!/usr/bin/env bash
# Runs Tavern with a made-up party (docs/demo) for screenshots: three fake Pi agents, sample mail,
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
  local transcript="$3"
  [[ "$transcript" == /* ]] || transcript="$PWD/docs/demo/$transcript"
  TAVERN_DURABLE_RUNTIME="$PWD/docs/demo/runtime.mjs" TAVERN_DURABLE_PORT="$2" TAVERN_DURABLE_HEARTBEAT_MINUTES=0 \
    TAVERN_DURABLE_REQUESTS="$home/$1-requests.json" AGENT_CWD="$home/$1" DEMO_NAME="$1" \
    DEMO_TRANSCRIPT="$transcript" DEMO_APPROVAL="${4:-}" node bridge/tavern-durable/host.mjs 2>/dev/null &
}
mkdir -p "$home/scout" "$home/forge" "$home/ivy/.pi"
# A pi-bundle agent card for discovery to find ("Found Moss on Garden Pi. Add?"); no host runs for it.
mkdir -p "$home/discovery/.config/pi-bundle/agents"
printf '{"id": "moss", "name": "Moss", "host": "Garden Pi", "partyClass": "Druid", "animal": "Tortoise", "avatarColor": "#5b7a3d", "port": 19614, "model": "ollama/qwen3.5:9b"}\n' \
  > "$home/discovery/.config/pi-bundle/agents/moss.json"
# Ivy's cider calls come back as MCP Apps cards. The data is made up (docs/demo/cards.py); the card
# pages come from the cider installed here, which the host starts but never asks for data.
python3 docs/demo/cards.py "$home"
if cider="$(command -v cider)"; then
  printf '{"mcpServers": {"cider": {"command": "%s", "args": ["mcp", "--sources", "weather,calendar,home"]}}}' "$cider" > "$home/ivy/.pi/mcp.json"
fi
host scout 19611 scout.json
host forge 19612 forge.json "docker rm -v staging-old-db"
host ivy 19613 "${IVY_TRANSCRIPT:-$home/ivy-day.json}"
trap 'kill $(jobs -p) 2>/dev/null' EXIT
sleep 1
TAVERN_HOME="$home" TAVERN_PAGE="${TAVERN_PAGE:-dashboard}" "$app/Contents/MacOS/Tavern" &
wait
