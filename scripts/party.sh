#!/usr/bin/env bash
# Copies the party's art, lore and spellbook from the Mac into iOS/Party, which the iPhone build
# bundles (gitignored: it's personal). Avatars and the portrait are scaled down; only the roster's
# name, lore and stars go. Used by phone.sh and testflight.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
roster="${TAVERN_ROSTER:-$HOME/Library/Application Support/Tavern/roster.json}"
tavern_home="${TAVERN_HOME:-$HOME/Library/Application Support/Tavern}"
party=iOS/Party
rm -rf "$party" && mkdir -p "$party/avatars"
for file in "$tavern_home"/avatars/*.{jpg,jpeg,png,heic}; do
  [ -f "$file" ] && sips -s format jpeg -Z 256 "$file" --out "$party/avatars/$(basename "${file%.*}").jpg" >/dev/null
done
for file in "$tavern_home"/portrait.{jpg,jpeg,png,heic}; do
  [ -f "$file" ] && { sips -s format jpeg -Z 1600 "$file" --out "$party/portrait.jpg" >/dev/null; break; }
done
# Goals on the phone needs the Linear team, and each member's name, color and owned projects.
[ -f "$roster" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); p={k: r[k] for k in ("partyName", "lore", "spellbookStars", "linearTeam") if k in r}; p["members"]=[{k: m[k] for k in ("id", "name", "avatarColor", "owns", "partyClass") if k in m} for m in r.get("members", [])]; json.dump(p, open(sys.argv[2], "w"))' "$roster" "$party/party.json"
# The Pi agents' hosts by tailnet name, for the phone to add itself.
if [ -f "$party/party.json" ] && command -v tailscale >/dev/null; then
  tailscale status --json 2>/dev/null | python3 scripts/phone-hosts.py "$roster" "$party/party.json" || echo "No tailnet hosts for the phone" >&2
fi
if [ -f "$tavern_home/spellbook/index.json" ]; then
  mkdir -p "$party/spellbook"
  (cd "$tavern_home/spellbook" && cp index.json "$OLDPWD/$party/spellbook/" && find skills -name SKILL.md -exec rsync -R {} "$OLDPWD/$party/spellbook/" \;)
  git -C "$tavern_home/spellbook" rev-parse --short HEAD > "$party/spellbook/COMMIT" 2>/dev/null || true
fi
