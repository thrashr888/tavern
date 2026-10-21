// Cheap heartbeats: the host checks for new mail, issues or anything else an MCP tool can list,
// without the model, and wakes the agent only when something is new, handing it just those
// items. A quiet check costs no tokens.
//
// <AGENT_CWD>/heartbeat.json lists the checks; each one calls a tool on one of the agent's MCP
// servers and reads a list of records from the result:
//
//   { "checks": [
//       { "name": "mail", "server": "pap", "tool": "read",
//         "arguments": { "connection": "Google", "tool": "emails_list", "params": { "search": "smithery" } } },
//       { "name": "linear", "server": "pap", "tool": "read",
//         "arguments": { "connection": "Linear", "tool": "issues_list", "params": {} } } ] }
//
// For the Personal Agent Proxy, a `connection` that's an integration name ("Google") is looked up
// with list_connections. Records are the result's `records` (or the first array in it), keyed by
// `id`. The first run only learns what's there; later runs report records it hasn't seen.
// Without heartbeat.json the host falls back to giving the agent HEARTBEAT.md on every beat.

import fs from "node:fs";
import path from "node:path";

const KEEP = 1000; // seen ids remembered per check

export function loadChecks(cwd) {
  try {
    const config = JSON.parse(fs.readFileSync(path.join(cwd, "heartbeat.json"), "utf8"));
    return Array.isArray(config.checks) && config.checks.length ? config.checks : null;
  } catch {
    return null;
  }
}

/** The structured result of an MCP tool call: structuredContent, else JSON in its text. */
function payload(result) {
  if (result?.structuredContent) return result.structuredContent;
  const text = (result?.content ?? []).find((c) => c?.type === "text")?.text;
  try {
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}

/** The list of records in a result: `records`, `data`, or the first array found. */
export function recordsOf(value) {
  if (Array.isArray(value)) return value;
  if (!value || typeof value !== "object") return [];
  for (const key of ["records", "data", "items", "results"]) if (Array.isArray(value[key])) return value[key];
  const first = Object.values(value).find(Array.isArray);
  return first ?? [];
}

/** One line for the agent: the record's id and its most telling fields. */
export function summarize(record) {
  const values = record?.values ?? record ?? {};
  const pick = ["subject", "title", "name", "from", "state", "status", "date", "updatedAt", "identifier"]
    .filter((k) => values[k] != null && values[k] !== "")
    .map((k) => `${k}: ${String(values[k]).replace(/\s+/g, " ").slice(0, 140)}`);
  return `${record?.id ?? "?"} (${pick.join("; ") || JSON.stringify(values).slice(0, 200)})`;
}

export class HeartbeatChecks {
  #servers;
  #checks;
  #statePath;
  #connections = new Map(); // server name -> { integration -> connection id }

  constructor(servers, checks, statePath) {
    this.#servers = servers;
    this.#checks = checks;
    this.#statePath = statePath;
  }

  #state() {
    try {
      return JSON.parse(fs.readFileSync(this.#statePath, "utf8"));
    } catch {
      return { checks: {} };
    }
  }

  async #connection(server, name) {
    if (/^[a-z0-9]{20,}$/.test(name)) return name; // already an id
    if (!this.#connections.has(server.name)) {
      const list = recordsOf(payload(await server.request("tools/call", { name: "list_connections", arguments: {} })));
      this.#connections.set(server.name, Object.fromEntries(list.map((c) => [String(c.integration ?? c.name ?? ""), c.connection ?? c.id])));
    }
    const id = this.#connections.get(server.name)[name];
    if (!id) throw new Error(`no ${name} connection on ${server.name}`);
    return id;
  }

  /**
   * Runs every check. Returns the new records (and per-check errors); remembers them as seen
   * unless `dryRun`. A check's first run only learns what's there.
   */
  async run({ dryRun = false } = {}) {
    const state = this.#state();
    const found = [];
    const errors = [];
    for (const check of this.#checks) {
      try {
        const server = this.#servers.find((s) => s.name === check.server);
        if (!server) throw new Error(`no MCP server ${check.server}`);
        const args = structuredClone(check.arguments ?? {});
        if (typeof args.connection === "string") args.connection = await this.#connection(server, args.connection);
        const result = await server.request("tools/call", { name: check.tool, arguments: args });
        if (result?.isError) throw new Error(JSON.stringify(payload(result) ?? result).slice(0, 200));
        const records = recordsOf(payload(result)).filter((r) => r?.id != null);
        const prior = state.checks[check.name];
        const seen = new Set(prior?.seen ?? []);
        const fresh = prior ? records.filter((r) => !seen.has(String(r.id))) : [];
        for (const record of fresh) found.push({ check: check.name, id: String(record.id), summary: summarize(record) });
        if (!dryRun) {
          const ids = [...records.map((r) => String(r.id)), ...(prior?.seen ?? [])];
          state.checks[check.name] = { seen: [...new Set(ids)].slice(0, KEEP), at: new Date().toISOString() };
        }
      } catch (error) {
        errors.push({ check: check.name, error: String(error?.message ?? error) });
      }
    }
    if (!dryRun) fs.writeFileSync(this.#statePath, JSON.stringify(state));
    return { found, errors };
  }
}

/** The message that wakes the agent: what's new, then the standing heartbeat instructions. */
export function wakeMessage(found, instructions, at) {
  const lines = found.map((item) => `- [${item.check}] ${item.summary}`).join("\n");
  return `[Heartbeat ${at}] New since the last check:\n${lines}\n\n${instructions ?? "Handle what's yours; tell the user what needs them."}`;
}
