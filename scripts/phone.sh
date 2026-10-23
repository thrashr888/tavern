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

# The party's art, lore and spellbook from the Mac, bundled into the app (iOS/Party is gitignored:
# it's personal). Avatars and the portrait are scaled down; only the roster's name, lore and stars go.
tavern_home="${TAVERN_HOME:-$HOME/Library/Application Support/Tavern}"
party=iOS/Party
rm -rf "$party" && mkdir -p "$party/avatars"
for file in "$tavern_home"/avatars/*.{jpg,jpeg,png,heic}; do
  [ -f "$file" ] && sips -s format jpeg -Z 256 "$file" --out "$party/avatars/$(basename "${file%.*}").jpg" >/dev/null
done
for file in "$tavern_home"/portrait.{jpg,jpeg,png,heic}; do
  [ -f "$file" ] && { sips -s format jpeg -Z 1600 "$file" --out "$party/portrait.jpg" >/dev/null; break; }
done
[ -f "$roster" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); json.dump({k: r[k] for k in ("partyName", "lore", "spellbookStars") if k in r}, open(sys.argv[2], "w"))' "$roster" "$party/party.json"
if [ -f "$tavern_home/spellbook/index.json" ]; then
  mkdir -p "$party/spellbook"
  (cd "$tavern_home/spellbook" && cp index.json "$OLDPWD/$party/spellbook/" && find skills -name SKILL.md -exec rsync -R {} "$OLDPWD/$party/spellbook/" \;)
  git -C "$tavern_home/spellbook" rev-parse --short HEAD > "$party/spellbook/COMMIT" 2>/dev/null || true
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
# Show the phone: Xcode 27 moved the Simulator window into Device Hub (Xcode > Open Developer
# Tool > Device Hub); older Xcodes have Simulator.app.
dev="$(xcode-select -p)"
for app in "$dev/../Applications/DeviceHub.app" "$dev/Applications/Simulator.app"; do
  if [ -d "$app" ]; then open "$app"; echo "Showing $device in $(basename "$app" .app)"; exit 0; fi
done
echo "Running on $device (xcrun simctl io $device screenshot shot.png)"
