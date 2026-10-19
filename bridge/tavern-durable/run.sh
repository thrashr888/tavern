#!/usr/bin/env bash
# Runs the durable host for one agent in the foreground (Ctrl-C stops it; the session survives).
#   ./run.sh flint            # session folder ~/Workspace/agents/flint, port 19011
#   AGENT_PORT=19012 ./run.sh ember
set -euo pipefail
agent="${1:?usage: run.sh <agent-id>}"
here="$(cd "$(dirname "$0")" && pwd)"
export PI_REPO="${PI_REPO:-$here/.pi}"
export AGENT_CWD="${AGENT_CWD:-$HOME/Workspace/agents/$agent}"
export TAVERN_DURABLE_PORT="${AGENT_PORT:-19011}"
mkdir -p "$AGENT_CWD"
exec node --import "$PI_REPO/packages/coding-agent/src/experimental/source-resolver.ts" "$here/host.mjs"
