// MCP servers as agent tools. Pi Durable v1.0 has no MCP client, so the host runs the servers
// listed in <AGENT_CWD>/.pi/mcp.json (the usual `mcpServers` format, stdio only), offers their
// tools to the agent as `<server>__<tool>`, and keeps MCP Apps cards (SEP-1865) with the results:
// a tool whose `_meta.ui.resourceUri` names a `ui://` resource gets `details.ui`, and Tavern
// reads that resource through the host to show the card.
//
// The agent's Personal Agent Proxy reads (mail, Linear, Docs) have no cards of their own; when the
// agent has pi-bundle's "cards" server, the host attaches its card for them, with PAP's answer as
// the card's structured content. That way they get cards without a second PAP login.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const PROTOCOL = "2025-06-18";
const UI_EXTENSION = "io.modelcontextprotocol/ui";
const UI_MIME = "text/html;profile=mcp-app";
const MAX_TEXT = 60_000;

/**
 * One stdio MCP server: line-delimited JSON-RPC over the child's stdin and stdout. If it exits
 * after starting (a remote proxy dropping, a crash), it starts again on its own with a growing
 * delay, and calls made meanwhile wait for it instead of failing at once.
 */
export class McpServer {
  #child;
  #next = 1;
  #pending = new Map();
  #buffer = "";
  #spec;
  #log;
  #closed = false;
  #retryMs = 1000;
  #back = null; // resolves when a restart finishes

  constructor(name, spec, log = () => {}) {
    this.name = name;
    this.tools = [];
    this.#spec = spec;
    this.#log = log;
    this.#spawn();
  }

  #spawn() {
    const { command, args = [], env = {} } = this.#spec;
    this.exited = false;
    this.#buffer = "";
    const child = spawn(command, args, { env: { ...process.env, ...env }, stdio: ["pipe", "pipe", "pipe"] });
    this.#child = child;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => this.#read(chunk));
    child.stderr.on("data", (chunk) => this.#log(`[mcp ${this.name}] ${String(chunk).trim()}`));
    let done = false;
    const ended = (why) => {
      if (done) return;
      done = true;
      this.exited = true;
      for (const { reject } of this.#pending.values()) reject(new Error(`${this.name} ${why}`));
      this.#pending.clear();
      if (this.started && !this.#closed) this.#restartLater(why);
    };
    child.on("exit", (code) => ended(`exited (${code})`));
    child.on("error", (error) => ended(`couldn't start: ${error.message}`));
    child.stdin.on("error", () => {});
  }

  #restartLater(why) {
    if (this.#back) return;
    const delay = this.#retryMs;
    this.#retryMs = Math.min(this.#retryMs * 2, 60_000);
    this.#log(`mcp ${this.name} ${why}; starting again in ${Math.round(delay / 1000)}s`);
    this.#back = new Promise((resolve) => {
      setTimeout(async () => {
        try {
          this.#spawn();
          await this.#initialize();
          this.#retryMs = 1000;
          this.#log(`mcp ${this.name} is back`);
        } catch (error) {
          this.#log(`mcp ${this.name} didn't come back: ${error.message}`);
        }
        this.#back = null;
        resolve();
        if (this.exited && !this.#closed) this.#restartLater("is still down");
      }, delay).unref?.();
    });
  }

  #read(chunk) {
    this.#buffer += chunk;
    let newline;
    while ((newline = this.#buffer.indexOf("\n")) >= 0) {
      const line = this.#buffer.slice(0, newline).trim();
      this.#buffer = this.#buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      const waiter = message.id != null ? this.#pending.get(message.id) : undefined;
      if (!waiter) continue; // Server requests and notifications aren't needed here.
      this.#pending.delete(message.id);
      message.error ? waiter.reject(new Error(message.error.message ?? "MCP error")) : waiter.resolve(message.result);
    }
  }

  async request(method, params = {}, timeoutMs = 60_000) {
    // Mid-restart: wait for it (bounded) rather than failing the agent's call outright.
    if (this.exited && this.#back) await Promise.race([this.#back, new Promise((r) => setTimeout(r, 30_000))]);
    if (this.exited) throw new Error(`${this.name} isn't running`);
    return this.#send(method, params, timeoutMs);
  }

  #send(method, params, timeoutMs) {
    const id = this.#next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`${this.name} ${method} timed out`));
      }, timeoutMs);
      this.#pending.set(id, {
        resolve: (value) => (clearTimeout(timer), resolve(value)),
        reject: (error) => (clearTimeout(timer), reject(error)),
      });
      this.#child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }

  notify(method, params = {}) {
    if (!this.exited) this.#child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }

  async #initialize() {
    const init = await this.#send("initialize", {
      protocolVersion: PROTOCOL,
      capabilities: { extensions: { [UI_EXTENSION]: { mimeTypes: [UI_MIME] } } },
      clientInfo: { name: "tavern-durable", version: "1" },
    }, 60_000);
    this.notify("notifications/initialized");
    this.info = init?.serverInfo ?? {};
    // The agent's tool list is fixed when the host starts; a restart refreshes what the server
    // reports (cards, annotations) for the tools it already offers.
    this.tools = (await this.#send("tools/list", {}, 60_000)).tools ?? this.tools;
  }

  async start() {
    await this.#initialize();
    this.started = true;
    return this;
  }

  close() {
    this.#closed = true;
    this.#child.kill();
  }

  /** For tests: stop the child as a crash would. */
  crash() {
    this.#child.kill();
  }
}

/** `_meta.ui.resourceUri` (or the deprecated flat key) when it's a `ui://` URI. */
export function uiResourceOf(tool) {
  const uri = tool?._meta?.ui?.resourceUri ?? tool?._meta?.["ui/resourceUri"];
  return typeof uri === "string" && uri.startsWith("ui://") ? uri : null;
}

/** Tool names are `<server>__<tool>`, limited to what model APIs accept. */
export function agentToolName(server, tool) {
  return `${server}__${tool}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 64);
}

/** What the model reads from a result: its text blocks, else its structured content as JSON. */
export function resultText(result) {
  const texts = (result?.content ?? []).filter((block) => block?.type === "text").map((block) => block.text);
  const text = texts.length ? texts.join("\n") : JSON.stringify(result?.structuredContent ?? {});
  return text.length > MAX_TEXT ? `${text.slice(0, MAX_TEXT)}\n[truncated]` : text;
}

/** The servers in `<cwd>/.pi/mcp.json` (or `file`), started; a server that fails is skipped. */
export async function startServers({ cwd, file, log = () => {} }) {
  const config = file ?? path.join(cwd, ".pi", "mcp.json");
  let servers;
  try {
    servers = JSON.parse(fs.readFileSync(config, "utf8")).mcpServers ?? {};
  } catch {
    return [];
  }
  const started = [];
  for (const [name, spec] of Object.entries(servers)) {
    if (!spec?.command) continue;
    try {
      started.push(await new McpServer(name, spec, log).start());
      log(`mcp ${name}: ${started.at(-1).tools.length} tools`);
    } catch (error) {
      log(`mcp ${name} failed: ${error.message}`);
    }
  }
  return started;
}

/** Which "cards" server card shows each PAP read, by PAP tool name. */
const PAP_CARDS = {
  emails_list: "ui://cards/mail", emails_get: "ui://cards/mail",
  issues_list: "ui://cards/linear", issues_get: "ui://cards/linear",
  files_list: "ui://cards/docs", files_get: "ui://cards/docs",
};

/** The card for a `pap__read` result: PAP's JSON answer (records, record or error) as it came. */
export function papCard(servers, server, tool, args, result) {
  const uri = server.name === "pap" && tool.name === "read" ? PAP_CARDS[args?.tool] : null;
  if (!uri || !servers.some((s) => s.name === "cards")) return null;
  let structuredContent = result?.structuredContent ?? null;
  if (!structuredContent) {
    const text = (result?.content ?? []).filter((c) => c?.type === "text").map((c) => c.text).join("\n");
    try {
      structuredContent = JSON.parse(text);
    } catch {
      structuredContent = { error: text || "No answer" };
    }
  }
  if (result?.isError && !structuredContent?.error) structuredContent = { error: JSON.stringify(structuredContent).slice(0, 500) };
  return { server: "cards", resourceUri: uri, structuredContent };
}

/** A Pi Durable extension offering every server's tools to the agent. */
export function mcpExtension(servers) {
  const tools = servers.flatMap((server) =>
    server.tools.map((tool) => {
      const ui = uiResourceOf(tool);
      const readOnly = tool.annotations?.readOnlyHint === true;
      return {
        name: agentToolName(server.name, tool.name),
        description: `${tool.description ?? tool.name} (MCP server ${server.name})`,
        parameters: tool.inputSchema ?? { type: "object", properties: {} },
        // A read-only tool can safely run again after a restart; anything else can't.
        replay: readOnly ? "safe" : "unsafe",
        async execute(args) {
          const result = await server.request("tools/call", { name: tool.name, arguments: args ?? {} });
          const details = { mcp: { server: server.name, tool: tool.name } };
          if (ui) details.ui = { server: server.name, resourceUri: ui, structuredContent: result?.structuredContent ?? null };
          else {
            const card = papCard(servers, server, tool, args, result);
            if (card) details.ui = card;
          }
          return { content: [{ type: "text", text: resultText(result) }], isError: result?.isError === true, details };
        },
      };
    }),
  );
  return { name: "tavern-mcp", tools };
}

/**
 * Reads a card for Tavern: only `ui://` resources a server's own tool points at, or the cards
 * server's cards the host attaches to PAP reads.
 */
export async function readCard(servers, serverName, uri) {
  const server = servers.find((s) => s.name === serverName);
  if (!server) throw new Error(`no MCP server ${serverName}`);
  const known = server.tools.some((tool) => uiResourceOf(tool) === uri)
    || (serverName === "cards" && Object.values(PAP_CARDS).includes(uri));
  if (!known) throw new Error(`${uri} isn't a card of ${serverName}`);
  const result = await server.request("resources/read", { uri });
  const content = (result?.contents ?? []).find((c) => c.uri === uri) ?? result?.contents?.[0];
  if (!content || !String(content.mimeType ?? "").startsWith("text/html")) throw new Error(`${uri} isn't an HTML card`);
  const html = content.text ?? Buffer.from(content.blob ?? "", "base64").toString("utf8");
  return { uri, mimeType: content.mimeType, html, meta: content._meta?.ui ?? {} };
}
