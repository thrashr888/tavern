#!/usr/bin/env bash
# The checks to run before pushing (Tavern builds on your Mac, not in GitHub Actions).
set -euo pipefail
cd "$(dirname "$0")/.."
(cd bridge/tavern-durable && npm test)
swift build -j "${JOBS:-4}"
swift test -j "${JOBS:-4}"
