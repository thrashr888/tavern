#!/usr/bin/env bash
# Builds the iPhone app (iOS/) and runs it in the iOS Simulator with the whole party. The
# Simulator shares this Mac's loopback, so:
#   - an agent whose host is on this Mac is at 127.0.0.1 as in roster.json;
#   - an agent Tavern reaches over SSH gets a local forward, through the same SSH setup the Mac
#     app uses (no new keys, no host changes): 127.0.0.1:19012, 19013, ...;
#   - a demo agent (docs/demo/phone-runtime.mjs) runs on 127.0.0.1:19614 for trying sends and
#     approvals safely.
#   scripts/phone.sh                     # everyone, from ~/Library/Application Support/Tavern/roster.json
#   TAVERN_AGENTS="Flint=127.0.0.1:19011" TAVERN_OPEN=flint scripts/phone.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Needs xcodegen: brew install xcodegen" >&2; exit 1; }

listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# The demo agent: a durable host on a pretend runtime.
demo_home=".build/phone-demo"
if ! listening 19614; then
  mkdir -p "$demo_home"
  TAVERN_DURABLE_RUNTIME="$PWD/docs/demo/phone-runtime.mjs" TAVERN_DURABLE_PORT=19614 TAVERN_DURABLE_HEARTBEAT_MINUTES=0 \
    TAVERN_DURABLE_REQUESTS="$demo_home/requests.json" AGENT_CWD="$demo_home" \
    nohup node bridge/tavern-durable/host.mjs >"$demo_home/host.log" 2>&1 &
fi

# The party: each Pi agent in the Mac's roster, as name=host:port for the phone.
roster="${TAVERN_ROSTER:-$HOME/Library/Application Support/Tavern/roster.json}"
if [ -z "${TAVERN_AGENTS:-}" ] && [ -f "$roster" ]; then
  agents=""
  next=19012
  while IFS=$'\t' read -r name kind host port; do
    case "$kind" in
      tcp) agents+="$name=$host:$port," ;;
      ssh)
        # One port per SSH agent, in roster order; one still listening is last run's forward.
        # The Mac app's own SSH config and keys; BatchMode so it never prompts.
        if listening "$next" || ssh -fN -o BatchMode=yes -o ExitOnForwardFailure=yes -L "$next:127.0.0.1:$port" "$host"; then
          agents+="$name=127.0.0.1:$next,"
        else
          echo "Can not reach $name on $host; leaving it out" >&2
        fi
        next=$((next + 1))
        ;;
    esac
  done < <(python3 scripts/phone-agents.py "$roster")
  TAVERN_AGENTS="${agents}Demo=127.0.0.1:19614"
fi

xcodegen generate --spec iOS/project.yml --quiet
device="${SIMULATOR:-$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/ {print $2; exit}')}"
[ -n "$device" ] || { echo "No iPhone simulator; install one with xcodebuild -downloadPlatform iOS" >&2; exit 1; }
xcrun simctl boot "$device" 2>/dev/null || true
xcodebuild -project iOS/TavernPhone.xcodeproj -scheme TavernPhone -destination "id=$device" \
  -derivedDataPath .build/ios-dd -quiet build
xcrun simctl install "$device" .build/ios-dd/Build/Products/Debug-iphonesimulator/TavernPhone.app
echo "Agents: ${TAVERN_AGENTS:-as saved in the app}"
SIMCTL_CHILD_TAVERN_AGENTS="${TAVERN_AGENTS:-}" SIMCTL_CHILD_TAVERN_OPEN="${TAVERN_OPEN:-}" \
  xcrun simctl launch --terminate-running-process "$device" dev.thrashr888.tavern.phone
# Newer Xcodes ship no Simulator app; the device still runs and screenshots work.
simulator="$(xcode-select -p)/Applications/Simulator.app"
[ -d "$simulator" ] && open "$simulator" || echo "Running on $device (xcrun simctl io $device screenshot shot.png)"
