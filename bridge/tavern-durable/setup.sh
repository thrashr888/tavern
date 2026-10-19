#!/usr/bin/env bash
# Fetches Pi at a pinned release into .pi/ next to this script and installs its dependencies.
# Local to this folder: no global install, no service. Pi Durable's API changes between releases,
# so bump PI_REF deliberately and rerun the tests. Stay at v1.1.x or earlier: v1.2.0 and main
# dropped packages/coding-agent/src/experimental/durable/runtime.ts, which host.mjs imports.
set -euo pipefail
PI_REF="${PI_REF:-v1.0.0}"
here="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$here/.pi/.git" ]; then
  git clone --depth 1 --branch "$PI_REF" https://github.com/earendil-works/pi.git "$here/.pi"
else
  git -C "$here/.pi" fetch --depth 1 origin "refs/tags/$PI_REF:refs/tags/$PI_REF"
  git -C "$here/.pi" checkout --quiet "$PI_REF"
fi
# Our one change to Pi: openDurable takes extra extensions (the approvals hook). Skipped when applied.
for patch in "$here"/patches/*.patch; do
  git -C "$here/.pi" apply --reverse --check "$patch" 2>/dev/null || git -C "$here/.pi" apply "$patch"
done
# Dependencies only. run.sh loads Pi from source, so Pi's own build isn't needed (and it fails
# offline-or-not on v1.0.0, because it regenerates today's model catalog).
(cd "$here/.pi" && npm install)
echo "Pi $PI_REF ready in $here/.pi"
