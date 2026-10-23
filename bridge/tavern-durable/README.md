# tavern-durable

One durable Pi session per agent, for Tavern.

Pi Durable is a library with no server or RPC mode, and only one process may own a session's storage. This host is that owner: it opens the agent's newest durable session (or creates it), keeps it alive, and serves the Pi RPC subset Tavern already speaks (`get_state`, `get_entries`, `prompt`, `steer`, `follow_up`, `abort`, `compact`, plus `message_update`, `tool_execution_*`, `agent_start` and `agent_settled` events) as line JSON on a loopback TCP port. Tavern attaches with a `tcp` endpoint, the same way it would reach a remote `pi --mode rpc`. There is no new-session or switch-session command.

## Run it

```sh
./setup.sh            # clones Pi v1.0.0 into .pi/ and installs its dependencies (local only)
./run.sh scout        # session in ~/Workspace/agents/scout, listens on 127.0.0.1:19011
```

Point Tavern at it in `~/Library/Application Support/Tavern/roster.json`:

```json
{ "id": "scout", "piEndpoint": { "kind": "tcp", "host": "127.0.0.1", "port": 19011 } }
```

It uses pi's own login and `settings.json` (default model, thinking level, compaction).

## Notes

- `TAVERN_DURABLE_DEBUG=1` prints the view's shape on start. `map.mjs` is the only file that knows Pi Durable's field names; if a release moves them, fix it there and add a test.
- Binds 127.0.0.1 by default. The host has no auth, so don't bind it to a network address (`TAVERN_DURABLE_BIND`); reach other machines over SSH instead (below).
- Reconnecting replays nothing from Pi Durable; Tavern catches up with `get_entries` since its cursor and dedups.
- Dedup: Pi v1.0/v1.1's `openDurable` controller doesn't pass a request id through, so the host keeps its own. Tavern sends a `requestId` (a UUID) on every prompt, steer and follow-up. The host records the newest 200 in `tavern-requests.json` next to `session.sqlite` (path override: `TAVERN_DURABLE_REQUESTS`), and answers a repeat with `disposition: "duplicate"` without running it. The id is recorded before the submit, so a crash in between drops that one message rather than running it twice.
- Heartbeat: if `<AGENT_CWD>/HEARTBEAT.md` exists, the host gives the agent that prompt every 30 minutes (`TAVERN_DURABLE_HEARTBEAT_MINUTES`, 0 turns it off), skipping a beat while it's busy. `get_state` reports `heartbeat: {everyMinutes, last, next}`.
- Cheap heartbeats: with `<AGENT_CWD>/heartbeat.json` (see `heartbeat.mjs`), each beat the host runs the listed checks itself, MCP tool calls such as the Personal Agent Proxy's `read` of `emails_list`, and remembers what it has seen in `.heartbeat-state.json`. Only new records start a turn, with those records and HEARTBEAT.md as the instructions; a quiet check costs no tokens. `heartbeat_check` runs the checks on demand without waking the agent. Tavern folds heartbeat turns into a collapsed row.
- Approvals: risky tool calls (recursive deletes, force-pushes, `sudo`, printing the environment, reading or changing files that hold keys, service changes; see `approvals.mjs`) wait for a `confirm` dialog in Tavern. The answer is a memo of the tool task, so a restart while waiting asks again and a restart after answering doesn't. `TAVERN_DURABLE_APPROVALS` is `risky` (default), `all` (every shell command and file change) or `off`. Needs `patches/pi-v1.0.0-extensions.patch`, which `setup.sh` applies. The rules catch mistakes and prompt-injected requests; a model determined to get around them can (a shell spells things many ways), so use `all` for an agent you don't trust.
- Always allow: a soft approval (not a hard rule) can be answered "Always allow": a shell command is then remembered by its program (`bash:npm`; chained or piped commands never are), anything else by the tool's name, in `always-allow.json` in the agent's folder, which the agent can't change unasked. `get_state.alwaysAllow` lists them and `forget_always_allow` takes one back (the agent's About tab in Tavern). See `always.mjs`.
- Judge: before one of the agent's own shell commands or file changes asks (other than the hard rules above), a local decision model (Clef through Ollama: a tag with the `decision` capability, Clef Flash first) says how sure it is the call is routine. At 85% or more (`TAVERN_DURABLE_JUDGE_MIN`) it runs without asking and Tavern gets a notice; below that, with no model, or for a command or path too long to show it whole, Paul decides, and the dialog shows the score. MCP tools always ask: they act on outside services. Nothing leaves the machine unless `TAVERN_DURABLE_JUDGE=jev`, which falls back to TypeSafe's Jev with the key Tavern uses (`TYPESAFE_API_KEY`, `TYPESAFE_API_KEY_FILE` or `~/.config/typesafe/api-key`) and sends it the call. The agent's folder and `TAVERN_DURABLE_WORKSPACE` count as its own. `off` turns it off. See `judge.mjs`.
- Self: the agent gets `my_info` (its model, spend, heartbeat, folders, approval policy and machine, as Tavern's info panel shows them) and `heartbeat_set` (minutes between beats, 0 pauses), which asks Paul first and keeps the choice in `heartbeat-schedule.json` across restarts. See `self.mjs`.
- Mail: `tools/mail.mjs` gives an agent Gmail from its shell (`search`, `read`, `thread`, `send`) using gmail-mcp's credential files, so the agent never reads the token itself (reading it asks for approval).
- MCP servers: list them in `<AGENT_CWD>/.pi/mcp.json` (the usual `mcpServers` format, stdio; or point `TAVERN_DURABLE_MCP` at another file). Pi Durable v1.0 has no MCP client, so the host runs them and offers their tools to the agent as `<server>__<tool>`. Tools that aren't read-only ask for approval. A tool with an MCP Apps card (`_meta.ui.resourceUri`) keeps it in the result's `details.ui`, and Tavern reads the card with `read_card` and shows it in the thread; a card's own button goes through `call_card_tool` after Tavern asks.
- Pi packages: the agent's own packages (the `packages` in `<AGENT_CWD>/.pi/settings.json`, installed on start when missing, plus `<AGENT_CWD>/.pi/extensions/`) load into the durable session through `pi-extensions.mjs`, since Pi Durable v1.0 doesn't load them itself. Their tools become agent tools, `before_agent_start` handlers render into a prompt section (refreshed for each new message), and `session_start`, `agent_end`, `session_compact` and `session_shutdown` fire from the host. Handlers get Pi's model registry and the session's model, so a package can use the agent's model access (pi-cortex passes it to Cortex). Commands, shortcuts, renderers and dialogs need a terminal and are ignored. Packages the machine's user installed for themselves in `~/.pi/agent` stay out, so every agent gets the same set from its bundle; `TAVERN_DURABLE_PI_EXTENSIONS=all` loads those too, and `off` skips them all.
- Events: `{"type":"event","source":"mail","text":"…","requestId":"…"}` hands the agent an outside happening as a follow-up, once per request id. Tavern sends new mail that greets an agent; cron jobs or webhooks on the machine can too.
- `npm test` runs the mapping and an end-to-end test against a fake runtime.
- Images sent with a message are saved in the agent's `attachments/` folder (named by content hash) and named in the message, since Pi Durable's controller takes text; the agent opens them with its read tool.

## Running as a service

Run each agent's host as a user service so its session outlives Tavern, crashes and logins:

- macOS: `services/launchagent.plist.template`, a LaunchAgent. Fill in the agent id and your home folder.
- Linux: `services/tavern-durable@.service.template`, a systemd user unit (`tavern-durable@<agent>`).

Pi v1.0.0's source tree needs the generated `packages/ai/src/providers/data/` and the packages' `dist/` folders, which `setup.sh` doesn't build; if they're missing, build Pi once (`npm run build` in `.pi`) or copy them from a machine that has them.

Remote hosts stay on loopback. Tavern reaches them over SSH with a `command` endpoint, e.g. `["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "my-server", "socat - TCP:127.0.0.1:19011"]`.
