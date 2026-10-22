// The judge: before a routine-looking tool call asks Paul, a decision model (Clef through local
// Ollama, else TypeSafe's Jev) says how sure it is the call is safe to run unasked. At or above
// the threshold it runs; below it, or with no model, it asks Paul as before. Only calls
// approvals.mjs calls soft get here: its hard rules (deletes, root, secrets) always ask.
//
// TAVERN_DURABLE_JUDGE: "auto" (default: local decision model, else Jev with a key) or "off".
// TAVERN_DURABLE_JUDGE_MIN: the probability of "routine" needed to run unasked (default 0.85).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const OLLAMA = process.env.OLLAMA_HOST?.replace(/\/$/, "") ?? "http://127.0.0.1:11434";
const JEV = { endpoint: "https://api.typesafe.ai/v1/systemone", model: "jev-1.13.0" };
// Tavern's order (Alchemy's benchmarks): Clef Flash first.
const FAMILIES = ["clef-flash", "clef", "nimble", "tev1"];
const RETRY_MS = 10 * 60_000;

const INSTRUCTIONS =
  "An AI agent wants to run the tool call in the state without asking its user first. Answer yes only if it is " +
  "a routine step: reading, searching, listing, cloning or pulling code, building, testing, formatting, or creating and editing files in the " +
  "agent's own folders, or a draft the user reviews before it goes anywhere. Answer no if it sends or publishes " +
  "anything, deletes or overwrites data outside those folders, pushes or merges code, installs or uninstalls " +
  "software, spends money, changes settings, accounts or permissions, controls devices, or you can't tell what it does.";

async function postJSON(url, body, { key, timeoutMs, fetchImpl = fetch }) {
  const response = await fetchImpl(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...(key ? { authorization: `Bearer ${key}` } : {}) },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

/** The best local decision model Ollama lists (capability "decision"), or null. */
export async function localBackend({ ollama = OLLAMA, fetchImpl = fetch } = {}) {
  try {
    const tags = await (await fetchImpl(`${ollama}/api/tags`, { signal: AbortSignal.timeout(3000) })).json();
    const decision = [];
    for (const { name } of tags.models ?? []) {
      const shown = await postJSON(`${ollama}/api/show`, { model: name }, { timeoutMs: 5000, fetchImpl }).catch(() => null);
      if (shown?.capabilities?.includes("decision")) decision.push(name);
    }
    const family = (tag) => { const i = FAMILIES.indexOf(tag.split(":")[0]); return i < 0 ? FAMILIES.length : i; };
    const model = decision.sort((a, b) => family(a) - family(b) || b.localeCompare(a))[0];
    return model ? { endpoint: `${ollama}/v1/systemone`, model, local: true } : null;
  } catch {
    return null;
  }
}

/** Jev with the key Tavern and Alchemy use: TYPESAFE_API_KEY, TYPESAFE_API_KEY_FILE, or ~/.config/typesafe/api-key. */
export function jevBackend(env = process.env, home = os.homedir()) {
  let key = env.TYPESAFE_API_KEY?.trim();
  for (const file of [env.TYPESAFE_API_KEY_FILE, path.join(home, ".config/typesafe/api-key")]) {
    if (key || !file) continue;
    try { key = fs.readFileSync(file, "utf8").trim(); } catch {}
  }
  return key && !/\s/.test(key) ? { ...JEV, key, local: false } : null;
}

/** What the model reads: the call, in full, and where the agent's own folders are. */
export function judgeState(call, reason, { cwd, workspace } = {}) {
  const folders = [cwd, workspace].filter(Boolean).join(" and ");
  return [
    `Agent's own folders: ${folders || "unknown"}`,
    `Why it would ask: it ${reason}`,
    `Tool: ${call?.name ?? "unknown"}`,
    `Arguments: ${JSON.stringify(call?.arguments ?? {}).slice(0, 6000)}`,
  ].join("\n");
}

export class Judge {
  #backend;
  #found = 0;
  #find;
  #fetch;
  #log;

  constructor({ mode = process.env.TAVERN_DURABLE_JUDGE ?? "auto", min = Number(process.env.TAVERN_DURABLE_JUDGE_MIN ?? 0.85),
    cwd, workspace, find, fetchImpl = fetch, log = () => {} } = {}) {
    this.mode = mode;
    this.min = min;
    this.folders = { cwd, workspace };
    this.#find = find ?? (async () => (await localBackend({ fetchImpl })) ?? jevBackend());
    this.#fetch = fetchImpl;
    this.#log = log;
  }

  async #backendNow() {
    if (this.#backend || Date.now() - this.#found < RETRY_MS) return this.#backend;
    this.#found = Date.now();
    this.#backend = await this.#find();
    if (this.#backend) this.#log(`judge: ${this.#backend.model}${this.#backend.local ? " (local)" : ""}`);
    return this.#backend;
  }

  /** `{allow, p, model}`, or null when there's no model or it failed (then Paul decides). */
  async verdict(call, reason) {
    if (this.mode === "off") return null;
    const backend = await this.#backendNow();
    if (!backend) return null;
    try {
      const raw = await postJSON(backend.endpoint, {
        model: backend.model,
        state: judgeState(call, reason, this.folders),
        questions: { routine: { type: "noul", instructions: INSTRUCTIONS } },
      }, { key: backend.key, timeoutMs: backend.local ? 30_000 : 15_000, fetchImpl: this.#fetch });
      const p = raw?.answers?.routine?.noul;
      if (raw?.answers?.routine?.type !== "noul" || typeof p !== "number" || p < 0 || p > 1) throw new Error("malformed answer");
      return { allow: p >= this.min, p, model: backend.model };
    } catch (error) {
      this.#log(`judge failed, asking Paul: ${error?.message ?? error}`);
      return null;
    }
  }
}
