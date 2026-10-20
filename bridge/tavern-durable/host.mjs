#!/usr/bin/env node
// tavern-durable: keeps one Pi Durable session alive for one agent and lets Tavern attach to it.
//
// It owns the session (Pi Durable allows one owner per storage and has no lock of its own), opens
// the newest session for the agent's folder or creates it, and serves the Pi RPC subset Tavern
// uses as line JSON over TCP. Tavern connects with a `tcp` endpoint in its roster, exactly as it
// would to a remote `pi --mode rpc`.
//
// Run it with pi's source resolver (see README.md), for example:
//   PI_REPO=~/Workspace/pi AGENT_CWD=~/Workspace/agents/flint \
//   node --import $PI_REPO/packages/coding-agent/src/experimental/source-resolver.ts host.mjs

import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { Approvals, approvalExtension } from "./approvals.mjs";
import { mcpExtension, readCard, resultText, startServers } from "./mcp.mjs";
import { agentStateOf, entriesSince, eventsBetween, liveOf, piEntries, usageOf } from "./map.mjs";
import { RequestLog } from "./requests.mjs";

const PI_REPO = process.env.PI_REPO ?? path.join(os.homedir(), "Workspace/pi");
const AGENT_CWD = process.env.AGENT_CWD ?? process.cwd();
// Loopback by default. Binding a tailnet address for a remote agent is a host decision for Paul.
const BIND = process.env.TAVERN_DURABLE_BIND ?? "127.0.0.1";
const PORT = Number(process.env.TAVERN_DURABLE_PORT ?? 19011);
const DEBUG = process.env.TAVERN_DURABLE_DEBUG === "1";
// Heartbeat: every N minutes (default 30) the host gives the agent the prompt in
// <AGENT_CWD>/HEARTBEAT.md, if that file exists. 0 turns it off.
const HEARTBEAT_MINUTES = Number(process.env.TAVERN_DURABLE_HEARTBEAT_MINUTES ?? 30);
const HEARTBEAT_FILE = path.join(AGENT_CWD, "HEARTBEAT.md");
// Risky tool calls wait for Paul: "risky" (default), "all" or "off". See approvals.mjs.
const APPROVALS = process.env.TAVERN_DURABLE_APPROVALS ?? "risky";

// TAVERN_DURABLE_RUNTIME swaps in a fake runtime for tests.
const runtimePath = process.env.TAVERN_DURABLE_RUNTIME ?? path.join(PI_REPO, "packages/coding-agent/src/experimental/durable/runtime.ts");
const runtime = await import(pathToFileURL(runtimePath).href);
const clients = new Set();
// The oldest open question goes to every client as a confirm dialog (Tavern shows one at a time).
const approvals = new Approvals((dialog) => dialog && broadcast(confirmRequest(dialog)));
// MCP servers from <AGENT_CWD>/.pi/mcp.json become agent tools; their changes ask like risky shell.
const mcpServers = await startServers({ cwd: AGENT_CWD, file: process.env.TAVERN_DURABLE_MCP, log });
const mcp = mcpExtension(mcpServers);
const mcpChanges = new Set(mcp.tools.filter((tool) => tool.replay !== "safe").map((tool) => tool.name));
const extensions = [approvalExtension(approvals, { policy: APPROVALS, cwd: AGENT_CWD, mcpChanges }), mcp];
// continueSession throws when the folder has no session yet; the first run creates it.
const durable = await runtime.openDurable({ cwd: AGENT_CWD, continueSession: true, extensions }).catch((error) => {
  if (!/No durable session exists/.test(String(error?.message))) throw error;
  return runtime.openDurable({ cwd: AGENT_CWD, continueSession: false, extensions });
});
const { view, controller } = durable;

const session = view.current().session ?? {};
log(`session ${session.id} in ${AGENT_CWD}`);
// Next to session.sqlite when the view says where that is.
const requests = new RequestLog(
  process.env.TAVERN_DURABLE_REQUESTS ??
    (session.directory
      ? path.join(session.directory, "tavern-requests.json")
      : path.join(os.homedir(), ".pi/agent/experimental/tavern", `${session.id ?? "session"}-requests.json`)),
);
if (DEBUG) logShape(view.current());
let lastLive = liveOf(view.current());
let lastEntryCount = piEntries(view.current()).length;
let lastNoticeIDs = new Set((view.current().notices ?? []).map((n) => n.id));

// The view batches its own updates; turn each burst into Pi RPC events for every client.
const unsubscribe = view.subscribe(() => {
  const current = view.current();
  const live = liveOf(current);
  const count = piEntries(current).length;
  const events = eventsBetween(lastLive, live, count > lastEntryCount);
  for (const notice of current.notices ?? []) {
    if (lastNoticeIDs.has(notice.id)) continue;
    events.push({ type: "extension_ui_request", id: `notice-${notice.id}`, method: "notify", message: notice.message, notifyType: notice.level });
  }
  lastNoticeIDs = new Set((current.notices ?? []).map((n) => n.id));
  lastLive = live;
  lastEntryCount = count;
  for (const event of events) broadcast(event);
});

const server = net.createServer((socket) => {
  clients.add(socket);
  socket.setEncoding("utf8");
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline).replace(/\r$/, "");
      buffer = buffer.slice(newline + 1);
      if (line.trim()) handle(socket, line);
    }
  });
  // A client that (re)connects while a tool waits sees the question again.
  const open = approvals.current();
  if (open) send(socket, confirmRequest(open));
  socket.on("close", () => clients.delete(socket));
  socket.on("error", () => clients.delete(socket));
});
server.listen(PORT, BIND, () => log(`listening on ${BIND}:${PORT}`));

async function handle(socket, line) {
  let command;
  try {
    command = JSON.parse(line);
  } catch {
    return;
  }
  const reply = (success, data, error) =>
    send(socket, { type: "response", id: command.id, command: command.type, success, data, error });
  try {
    const current = view.current();
    switch (command.type) {
      case "get_state": {
        const live = liveOf(current);
        const { model, thinkingLevel } = agentStateOf(current);
        return reply(true, { sessionId: String(current.session?.id ?? "durable"), isStreaming: live.busy, durable: true, model, thinkingLevel,
                             heartbeat: heartbeatState(), usage: usageOf(current),
                             pendingApprovals: approvals.size });
      }
      case "get_entries": {
        const entries = entriesSince(piEntries(current), command.since);
        if (entries == null) return reply(false, undefined, `unknown entry ${command.since}`);
        const all = piEntries(current);
        return reply(true, { entries, leafId: all.at(-1)?.id ?? null });
      }
      case "prompt":
      case "steer":
      case "follow_up": {
        // A resent request id was already submitted: answer as before, don't run it again.
        if (!requests.claim(command.requestId)) return reply(true, { disposition: "duplicate" });
        // Durable queues safely when busy, so a prompt without streamingBehavior means follow-up.
        const steer = command.type === "steer" || (command.type === "prompt" && command.streamingBehavior === "steer");
        const busy = liveOf(current).busy;
        const text = withAttachments(String(command.message ?? ""), command.images);
        background(controller.submit(text, steer ? "steer" : "followUp"));
        return reply(true, { disposition: command.type === "prompt" && !busy ? "started" : "queued" });
      }
      case "event": {
        // Something happened outside (new mail, a webhook, a cron job): hand it to the agent as a
        // follow-up, once per requestId.
        if (!requests.claim(command.requestId)) return reply(true, { disposition: "duplicate" });
        const source = String(command.source ?? "event").slice(0, 60);
        const text = String(command.text ?? "").slice(0, 8000);
        if (!text.trim()) return reply(false, undefined, "event needs text");
        const busy = liveOf(current).busy;
        background(controller.submit(`[Event from ${source}]\n${text}`, "followUp"));
        return reply(true, { disposition: busy ? "queued" : "started" });
      }
      case "read_card": {
        // An MCP Apps card for a tool result Tavern shows (details.ui in the transcript).
        const card = await readCard(mcpServers, String(command.server ?? ""), String(command.uri ?? ""));
        return reply(true, card);
      }
      case "call_card_tool": {
        // A card's own button calling a tool of its server. Tavern asks Paul before sending this.
        const server = mcpServers.find((s) => s.name === command.server);
        const tool = server?.tools.find((t) => t.name === command.name);
        if (!tool) return reply(false, undefined, `no tool ${command.name} on ${command.server}`);
        const result = await server.request("tools/call", { name: tool.name, arguments: command.arguments ?? {} });
        log(`card called ${server.name}/${tool.name}`);
        return reply(true, { ...result, text: resultText(result) });
      }
      case "abort":
        await controller.abort();
        return reply(true);
      case "compact":
        background(controller.compact(command.customInstructions));
        return reply(true);
      case "extension_ui_response":
        // Approval answers; notices need none. Cancel counts as no.
        approvals.answer(String(command.id ?? ""), command.confirmed === true);
        return;
      default:
        // No new-session or switch-session commands, by design: one session per agent.
        return reply(false, undefined, `unsupported command ${command.type}`);
    }
  } catch (error) {
    reply(false, undefined, String(error?.message ?? error));
  }
}

let lastHeartbeat = null;
let nextHeartbeat = null;

function heartbeatPrompt() {
  try {
    const text = fs.readFileSync(HEARTBEAT_FILE, "utf8").trim();
    return text || null;
  } catch {
    return null;
  }
}

function heartbeatState() {
  if (HEARTBEAT_MINUTES <= 0 || !heartbeatPrompt()) return null;
  return { everyMinutes: HEARTBEAT_MINUTES, last: lastHeartbeat, next: nextHeartbeat };
}

/** Runs the heartbeat prompt on schedule; skips a beat while the agent is busy. */
function scheduleHeartbeat(delayMs) {
  if (HEARTBEAT_MINUTES <= 0) return;
  nextHeartbeat = new Date(Date.now() + delayMs).toISOString();
  setTimeout(() => {
    const prompt = heartbeatPrompt();
    if (prompt && !liveOf(view.current()).busy) {
      lastHeartbeat = new Date().toISOString();
      background(controller.submit(`[Heartbeat ${lastHeartbeat}]\n${prompt}`, "followUp"));
    }
    scheduleHeartbeat(HEARTBEAT_MINUTES * 60_000);
  }, delayMs).unref();
}
// First beat five minutes after start, so a restart doesn't fire one immediately.
scheduleHeartbeat(Number(process.env.TAVERN_DURABLE_HEARTBEAT_FIRST_MS ?? 5 * 60_000));

/** Controller commands queue and may resolve only when done; answer now, report failures as notices. */
function background(promise) {
  promise.catch((error) =>
    broadcast({ type: "extension_ui_request", id: `error-${Date.now()}`, method: "notify", message: String(error?.message ?? error), notifyType: "error" }),
  );
}

function confirmRequest(dialog) {
  return { type: "extension_ui_request", id: dialog.id, method: "confirm", title: dialog.title, message: dialog.message };
}

function send(socket, record) {
  if (!socket.destroyed) socket.write(JSON.stringify(record) + "\n");
}

function broadcast(record) {
  for (const socket of clients) send(socket, record);
}

function log(message) {
  process.stderr.write(`[tavern-durable] ${message}\n`);
}

/** Prints the view's top-level keys and the pi.live document's shape once, to fix map.mjs. */
function logShape(current) {
  const conversation = current.conversation ?? {};
  log(`view keys: ${Object.keys(current).join(", ")}`);
  log(`conversation keys: ${Object.keys(conversation).join(", ")}`);
  log(`docs: ${Object.keys(conversation.docs ?? {}).join(", ")}`);
  const sample = (conversation.entries ?? []).at(-1);
  if (sample) log(`last entry keys: ${Object.keys(sample).join(", ")}`);
  log(`pi.live keys: ${Object.keys(conversation.docs?.["pi.live"] ?? {}).join(", ")}`);
}

async function shutdown() {
  unsubscribe();
  for (const mcpServer of mcpServers) mcpServer.close();
  server.close();
  for (const socket of clients) socket.destroy();
  await durable.close();
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

// Pi Durable's controller takes text only, so images from Tavern are saved in the agent's
// workspace and named in the message; the agent opens them with its read tool.
const EXTENSIONS = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic" };
function withAttachments(text, images) {
  if (!Array.isArray(images) || images.length === 0) return text;
  const dir = path.join(AGENT_CWD, "attachments");
  fs.mkdirSync(dir, { recursive: true });
  const saved = [];
  images.slice(0, 8).forEach((image) => {
    const ext = EXTENSIONS[image?.mimeType];
    if (!ext || typeof image.data !== "string") return;
    const bytes = Buffer.from(image.data, "base64");
    // Named by content, so Tavern can show its own copy of the same image inline.
    const name = crypto.createHash("sha256").update(bytes).digest("hex").slice(0, 16);
    const file = path.join(dir, `${name}.${ext}`);
    fs.writeFileSync(file, bytes);
    saved.push(file);
  });
  if (saved.length === 0) return text;
  const list = saved.map((file) => `- ${file}`).join("\n");
  return `${text}\n\nAttached image${saved.length === 1 ? "" : "s"} (open with your read tool):\n${list}`;
}
