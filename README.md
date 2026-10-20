# Tavern

A native Mac app for running a party of AI agents: the ones you can steer live, and the ones
that live elsewhere and talk to you by email or iMessage.

![The Dashboard: what needs you, mail and agent activity, and the party](docs/screenshots/dashboard.png)

- **Pi agents, live.** Each [Pi](https://github.com/earendil-works/pi) agent has one durable
  thread: streaming replies, tool steps, steer and queue, abort, approvals, images. Agents can
  run on this Mac or on other machines reached over SSH (see `bridge/tavern-durable`). The host
  runs each agent's `HEARTBEAT.md` every 30 minutes, and Tavern can forward new mail that greets
  an agent as an event (`mailEvents` in the roster).
- **Hosted agents.** Members you can't reach live (ChatGPT, Claude, Grok…) get a page built from
  the party's shared Gmail label, plus an iMessage conversation when they have a handle.
- **Needs you.** The Dashboard starts with what's waiting on you: agents blocked on a question,
  mail that asks for you, unanswered iMessages, failed connections and finished tasks.
- **Goals.** Your Linear team's open issues with filters, agent tags, editing, New Ticket and
  "send to an agent".
- **Tool cards.** When an agent's tool comes with an [MCP Apps](https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp)
  card, the thread shows it inline. [cider](https://github.com/thrashr888/cider) gives Pi agents
  cards for weather, calendar, reminders, stocks, Home, Music, photos, contacts and the Mac's own
  status (list it in the agent's `.pi/mcp.json`; see `bridge/tavern-durable`).
- **Services.** Docker containers on each agent's machine.
- **Lore.** Links to the party's shared docs and boards.

| A Pi agent's thread | An approval waiting on you |
| --- | --- |
| ![Scout's thread: a fix, its tool steps and a PR](docs/screenshots/agent.png) | ![Forge asks before removing a Docker volume](docs/screenshots/approval.png) |

![Party mail, threaded and attributed to members](docs/screenshots/mail.png)

### Cards from cider

Pi agents get Mac tools from [cider](https://github.com/thrashr888/cider), and its results come
back as cards: no network access, links open in your browser, and a button that changes
something (a light, a scene, a song) asks first.

| Weather and the day's agenda | Home, with lights and scenes to tap |
| --- | --- |
| ![Ivy answers "what does my day look like?" with cider's weather and agenda cards](docs/screenshots/cards.png) | ![Ivy shows which lights are on with cider's Home card](docs/screenshots/home.png) |

Screenshots show a made-up party, cards included (the card pages come from cider; the data is
invented). `scripts/demo.sh` runs it (fake agents, sample mail, its own
data folder via `TAVERN_HOME`), and `scripts/screenshots.sh` retakes these images.

## Install (Apple silicon, macOS 14+)

```bash
brew install --cask thrashr888/tap/tavern
```

## Build and run

```bash
scripts/check.sh       # durable host tests, swift build, swift test (no CI; run before pushing)
scripts/bundle.sh      # builds a release Tavern.app into ~/Applications and opens it
```

## Configure

Everything about your party lives in `~/Library/Application Support/Tavern/`, not in this repo.
Tavern > Settings (⌘,) edits most of it: the party's name and image, members with their classes,
colors, avatars and connections, the mail label, the Linear team and Lore links.

Tavern also finds Pi agents for you. Each [pi-bundle](https://github.com/thrashr888/pi-bundle)
install leaves an agent card in `~/.config/pi-bundle/agents/`; Tavern reads the cards on this Mac,
and over your own SSH on the online Macs and Linux boxes of your tailnet, then offers "Found Ember
on M3. Add?" on the Dashboard and in Settings. Without Tailscale it looks on this Mac only.

- `roster.json`: what Settings saves. Keys it doesn't know are kept, and the first save leaves the
  old file as `roster.json.before-settings`. A few fields are still file-only (owner maps, trusted
  senders, sign-offs); see [docs/roster.example.json](docs/roster.example.json). Without the file
  Tavern shows a two-member example party.
- `portrait.png` and `avatars/<id>.png`: party art, set in Settings. Members without art get an initial.
- `gmail-oauth-client.json`: a desktop OAuth client from your own Google Cloud project, for the
  mail feed (scope `gmail.modify`: Tavern reads, and archives a thread when you ask; it never
  sends or deletes). Tavern stores the token in your keychain.
- `~/.config/linear-key`: a Linear API key, for Goals. Tavern sends read queries, plus agent
  labels, new issues and edits to an issue's title, description, status, priority and project.
- iMessage uses [cider](https://github.com/thrashr888/cider) and needs Full Disk Access for
  Tavern to read your Messages history.

## Layout

- `Sources/TavernCore`: models, SQLite event store, roster, Pi RPC, Gmail, Linear, Docker. No UI.
- `Sources/TavernApp`: the SwiftUI app.
- `Tests/TavernCoreTests`: unit tests for the core.
- `bridge/tavern-durable`: the Node host that keeps one Pi Durable session per agent.

No credentials are stored in this repo.
