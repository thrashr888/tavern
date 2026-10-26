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
import { ASK_PREFIX, askExtension } from "./ask.mjs";
import { Judge } from "./judge.mjs";
import { capabilities } from "./capabilities.mjs";
import { savedMinutes, selfExtension } from "./self.mjs";
import { AlwaysAllow } from "./always.mjs";
import { mcpExtension, readCard, resultText, startServers } from "./mcp.mjs";
import { HeartbeatChecks, beatsThisWeek, loadChecks, recordBeat, wakeMessage } from "./heartbeat.mjs";
import { agentStateOf, entriesSince, eventsBetween, liveOf, piEntries, usageOf } from "./map.mjs";
import { RequestLog } from "./requests.mjs";
import { loadPiExtensions, piExtensionBridge } from "./pi-extensions.mjs";

const PI_REPO = process.env.PI_REPO ?? path.join(os.homedir(), "Workspace/pi");
const AGENT_CWD = process.env.AGENT_CWD ?? process.cwd();
// Loopback by default. Binding a tailnet address for a remote agent is a host decision for Paul.
const BIND = process.env.TAVERN_DURABLE_BIND ?? "127.0.0.1";
const PORT = Number(process.env.TAVERN_DURABLE_PORT ?? 19011);
const DEBUG = process.env.TAVERN_DURABLE_DEBUG === "1";
// Heartbeat: every N minutes (default 30). With <AGENT_CWD>/heartbeat.json the host runs its
// checks itself (no model) and wakes the agent only for new items, with HEARTBEAT.md as the
// instructions; without it, the agent gets HEARTBEAT.md every beat. 0 turns it off.
// The agent can change it (heartbeat_set, after Paul allows it); its choice is kept in heartbeat-schedule.json.
let heartbeatMinutes = savedMinutes(AGENT_CWD, Number(process.env.TAVERN_DURABLE_HEARTBEAT_MINUTES ?? 30));
const HEARTBEAT_FILE = path.join(AGENT_CWD, "HEARTBEAT.md");
// Pickup: with heartbeat.json, run its checks every N minutes on their own timer, between beats,
// so new mail and issues reach the agent in minutes. 0 (default) runs them only on the beat.
const CHECK_MINUTES = Number(process.env.TAVERN_DURABLE_CHECK_MINUTES ?? 0);
// Risky tool calls wait for Paul: "risky" (default), "all" or "off". See approvals.mjs.
const APPROVALS = process.env.TAVERN_DURABLE_APPROVALS ?? "risky";
// Standard Pi packages load into the session: the agent's own (<AGENT_CWD>/.pi), "all" adds the
// machine user's ~/.pi/agent ones, "off" loads none.
const PI_EXTENSIONS = process.env.TAVERN_DURABLE_PI_EXTENSIONS ?? "on";

// TAVERN_DURABLE_RUNTIME swaps in a fake runtime for tests.
const runtimePath = process.env.TAVERN_DURABLE_RUNTIME ?? path.join(PI_REPO, "packages/coding-agent/src/experimental/durable/runtime.ts");
const runtime = await import(pathToFileURL(runtimePath).href);
const clients = new Set();
// The oldest open question goes to every client as a confirm dialog (Tavern shows one at a time).
// The ask tool's select and input dialogs share the queue.
const approvals = new Approvals((dialog) => dialog && broadcast(dialogRequest(dialog)));
// MCP servers from <AGENT_CWD>/.pi/mcp.json become agent tools; their changes ask like risky shell.
const mcpServers = await startServers({ cwd: AGENT_CWD, file: process.env.TAVERN_DURABLE_MCP, log });
const mcp = mcpExtension(mcpServers);
// What the machine offers (MCP servers, containers, CLIs), for the agent's card; refreshed now and then.
let machine = await capabilities(mcpServers);
setInterval(async () => { machine = await capabilities(mcpServers); }, 5 * 60_000).unref();
// PAP's start_task and finish_task only file the agent's calls under a task; they change nothing
// the user has, so they don't ask. Its run (and send_feedback) still do.
const bookkeeping = new Set(["pap__start_task", "pap__finish_task"]);
// Tavern's own tools (the home agent's "tavern" server) ask the user in Tavern itself.
const asksItself = (name) => name.startsWith("tavern__");
const mcpChanges = new Set(mcp.tools.filter((tool) => tool.replay !== "safe" && !bookkeeping.has(tool.name) && !asksItself(tool.name)).map((tool) => tool.name));
// A decision model lets routine calls run unasked (judge.mjs); the agent's own folders are routine.
const judge = new Judge({ cwd: AGENT_CWD, workspace: process.env.TAVERN_DURABLE_WORKSPACE, log });
const notify = (message) => broadcast({ type: "extension_ui_request", id: `judge-${Date.now()}`, method: "notify", message, notifyType: "info" });
const selfTools = selfExtension({ approvals, cwd: AGENT_CWD, name: process.env.AGENT_NAME, info: selfInfo, setMinutes: setHeartbeatMinutes });
// What Paul said to always allow, per agent (always-allow.json in its folder).
const always = new AlwaysAllow(process.env.TAVERN_DURABLE_STATE ??
  path.join(os.homedir(), ".local/state/tavern-durable", `${path.basename(AGENT_CWD)}-${crypto.createHash("sha256").update(AGENT_CWD).digest("hex").slice(0, 8)}`));
const extensions = [approvalExtension(approvals, { policy: APPROVALS, cwd: AGENT_CWD, mcpChanges, judge, notify, always }), askExtension(approvals), selfTools, mcp];
// Pi packages installed for this agent, such as its memory. TAVERN_DURABLE_PI_LOADER swaps in a
// fake loader for tests. The bridge's callbacks reach the controller once the session is open.
const piLoaded = PI_EXTENSIONS === "off" ? null : await loadPi().catch((error) => (log(`pi extensions skipped: ${error?.message ?? error}`), null));
const pi = piExtensionBridge(piLoaded, {
  cwd: AGENT_CWD,
  submit: (text) => background(submit(text, "followUp")),
  compact: (instructions) => background(controller.compact(instructions)),
  abort: () => controller.abort(),
  isIdle: () => !liveOf(view.current()).busy,
  model: () => agentStateOf(view.current()).model,
  notify: (message, level) => broadcast({ type: "extension_ui_request", id: `pi-${Date.now()}`, method: "notify", message, notifyType: level }),
  log,
});
if (pi.names.length) log(`pi extensions: ${pi.names.join(", ")}`);
if (pi.extension.tools.length || pi.extension.sections.length) extensions.push(pi.extension);
// continueSession throws when the folder has no session yet; the first run creates it.
const durable = await runtime.openDurable({ cwd: AGENT_CWD, continueSession: true, extensions }).catch((error) => {
  if (!/No durable session exists/.test(String(error?.message))) throw error;
  return runtime.openDurable({ cwd: AGENT_CWD, continueSession: false, extensions });
});
const { view, controller } = durable;
await pi.emit({ type: "session_start", reason: "startup" });

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
let compactionIDs = new Set(piEntries(view.current()).filter((e) => e.type === "compaction").map((e) => e.id));

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
  // Pi packages hear about settled turns and new compactions (a memory package consolidates then).
  if (lastLive.busy && !live.busy) background(pi.emit({ type: "agent_end", messages: [] }));
  for (const entry of piEntries(current)) {
    if (entry.type !== "compaction" || compactionIDs.has(entry.id)) continue;
    compactionIDs.add(entry.id);
    background(pi.emit({ type: "session_compact", compactionEntry: { id: entry.id, timestamp: entry.timestamp }, fromExtension: false, reason: "threshold", willRetry: false }));
  }
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
  if (open) send(socket, dialogRequest(open));
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
                             pendingApprovals: approvals.size, capabilities: machine, alwaysAllow: always.list() });
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
        background(submit(text, steer ? "steer" : "followUp"));
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
        background(submit(`[Event from ${source}]\n${text}`, "followUp"));
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
      case "heartbeat_check": {
        // Runs the checks now and reports what's new, without waking the agent or marking it seen.
        const checks = heartbeatChecks();
        if (!checks) return reply(false, undefined, "no heartbeat.json for this agent");
        return reply(true, await checks.run({ dryRun: true }));
      }
      case "abort":
        await controller.abort();
        return reply(true);
      case "compact":
        background(controller.compact(command.customInstructions));
        return reply(true);
      case "forget_always_allow":
        return reply(true, { removed: always.remove(String(command.key ?? "")), alwaysAllow: always.list() });
      case "extension_ui_response": {
        // Approval answers (cancel counts as no) and ask answers; notices need none.
        const id = String(command.id ?? "");
        if (id.startsWith(ASK_PREFIX)) approvals.reply(id, typeof command.value === "string" ? { value: command.value } : { cancelled: true });
        else approvals.answer(id, command.confirmed === true, undefined, command.always === true);
        return;
      }
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
let lastCheck = null;
let lastFound = 0;
let lastCheckErrors = [];
/** Each check's result for two weeks, so Tavern can count quiet beats (turns not spent). */
const BEATS_LOG = path.join(AGENT_CWD, ".heartbeat-log.json");

/** The checks in heartbeat.json, read on each beat so editing it needs no restart. */
function heartbeatChecks() {
  const checks = loadChecks(AGENT_CWD);
  return checks ? new HeartbeatChecks(mcpServers, checks, path.join(AGENT_CWD, ".heartbeat-state.json")) : null;
}

function heartbeatPrompt() {
  try {
    const text = fs.readFileSync(HEARTBEAT_FILE, "utf8").trim();
    return text || null;
  } catch {
    return null;
  }
}

function heartbeatState() {
  const hasChecks = loadChecks(AGENT_CWD) != null;
  if (heartbeatMinutes <= 0 || (!heartbeatPrompt() && !hasChecks)) return null;
  return { everyMinutes: heartbeatMinutes, last: lastHeartbeat, next: nextHeartbeat,
           checks: hasChecks ? { everyMinutes: CHECK_MINUTES || heartbeatMinutes, last: lastCheck, found: lastFound, errors: lastCheckErrors, week: beatsThisWeek(BEATS_LOG) } : null };
}

/** One beat: checks first when configured (waking the agent only for new items), else the prompt. */
async function heartbeat() {
  const prompt = heartbeatPrompt();
  const checks = heartbeatChecks();
  if (!checks) {
    if (!prompt || liveOf(view.current()).busy) return; // skip this beat while busy
    lastHeartbeat = new Date().toISOString();
    background(submit(`[Heartbeat ${lastHeartbeat}]\n${prompt}`, "followUp"));
    return;
  }
  runChecks(checks, prompt);
}

let checking = null; // the check (and its hand-off) in flight; the next one waits its turn
/**
 * Runs the checks and hands anything new to the agent as a follow-up (Durable queues it while the
 * agent is busy). Records are marked seen only after the hand-off, so a failed submit finds them
 * again next time instead of losing them.
 */
function runChecks(checks, prompt) {
  if (checking) return checking;
  checking = (async () => {
    const { found, errors, save } = await checks.run({ defer: true });
    lastCheck = new Date().toISOString();
    lastFound = found.length;
    lastCheckErrors = errors;
    if (!errors.length || found.length) recordBeat(BEATS_LOG, found.length);
    if (errors.length) log(`heartbeat checks: ${errors.map((e) => `${e.check}: ${e.error}`).join("; ")}`);
    if (found.length) {
      lastHeartbeat = lastCheck;
      await submit(wakeMessage(found, prompt, lastCheck), "followUp");
      log(`picked up ${found.length}: ${found.map((f) => `${f.check}:${f.id}`).join(", ").slice(0, 500)}`);
    }
    save();
  })().catch((error) => log(`checks failed: ${error?.message ?? error}`)).finally(() => { checking = null; });
  return checking;
}

if (CHECK_MINUTES > 0) {
  setInterval(() => {
    const checks = heartbeatChecks();
    if (checks) runChecks(checks, heartbeatPrompt());
  }, CHECK_MINUTES * 60_000).unref();
  log(`checks every ${CHECK_MINUTES} min`);
}

let heartbeatTimer = null;
function scheduleHeartbeat(delayMs) {
  clearTimeout(heartbeatTimer);
  nextHeartbeat = null;
  if (heartbeatMinutes <= 0) return;
  nextHeartbeat = new Date(Date.now() + delayMs).toISOString();
  heartbeatTimer = setTimeout(async () => {
    try { await heartbeat(); } catch (error) { log(`heartbeat failed: ${error?.message ?? error}`); }
    scheduleHeartbeat(heartbeatMinutes * 60_000);
  }, delayMs);
  heartbeatTimer.unref();
}

function setHeartbeatMinutes(minutes) {
  heartbeatMinutes = minutes;
  scheduleHeartbeat(minutes * 60_000);
  log(minutes ? `heartbeat every ${minutes} min` : "heartbeat paused");
}

/** What the agent's my_info tool reads: Tavern's info panel, from the agent's side. */
function selfInfo() {
  const current = view.current();
  const { model, thinkingLevel } = agentStateOf(current);
  return {
    model, thinkingLevel, usage: usageOf(current),
    heartbeat: { everyMinutes: heartbeatMinutes, paused: heartbeatMinutes <= 0, file: heartbeatPrompt() ? HEARTBEAT_FILE : null,
                 checks: loadChecks(AGENT_CWD) ? path.join(AGENT_CWD, "heartbeat.json") : null, ...(heartbeatState() ?? {}) },
    folders: { session: AGENT_CWD, workspace: process.env.TAVERN_DURABLE_WORKSPACE ?? null },
    approvals: { policy: APPROVALS, waiting: approvals.size },
    machine,
  };
}
// First beat five minutes after start, so a restart doesn't fire one immediately.
scheduleHeartbeat(Number(process.env.TAVERN_DURABLE_HEARTBEAT_FIRST_MS ?? 5 * 60_000));

/** Submits to the session, telling Pi packages what the agent is about to read. */
function submit(text, whenBusy) {
  pi.setPrompt(text);
  return controller.submit(text, whenBusy);
}

/** Pi's loader, or the test's. */
async function loadPi() {
  if (process.env.TAVERN_DURABLE_PI_LOADER) {
    const fake = await import(pathToFileURL(process.env.TAVERN_DURABLE_PI_LOADER).href);
    return fake.loadPiExtensions({ cwd: AGENT_CWD });
  }
  // "all" also loads what the machine's user installed for themselves in ~/.pi/agent.
  return loadPiExtensions({ piRepo: PI_REPO, cwd: AGENT_CWD, scope: PI_EXTENSIONS === "all" ? "all" : "project", log });
}

/** Controller commands queue and may resolve only when done; answer now, report failures as notices. */
function background(promise) {
  promise.catch((error) =>
    broadcast({ type: "extension_ui_request", id: `error-${Date.now()}`, method: "notify", message: String(error?.message ?? error), notifyType: "error" }),
  );
}

function dialogRequest(dialog) {
  const { id, method = "confirm", title, message, options, placeholder, always } = dialog;
  // `always`: the label for an "Always allow" answer (`confirmed` plus `always: true`).
  return { type: "extension_ui_request", id, method, title, message, ...(options ? { options } : {}), ...(placeholder ? { placeholder } : {}),
           ...(always ? { always } : {}) };
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
  await pi.emit({ type: "session_shutdown", reason: "quit" });
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
