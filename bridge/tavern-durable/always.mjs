// "Always allow": tools Paul has told an agent to run without asking again, kept in
// <AGENT_CWD>/always-allow.json (a file the agent can't change without asking). A shell command
// is remembered by its program ("npm", "git"), anything else by the tool's name. Only calls the
// approvals call soft are ever remembered or skipped: the hard rules (deletes, root, secrets,
// force-push) always ask.

import fs from "node:fs";
import path from "node:path";

export const ALWAYS_FILE = "always-allow.json";

/** What "always allow" remembers for a call, or null when it can't be remembered safely. */
export function alwaysKey(call) {
  if (call?.name !== "bash") return call?.name ? String(call.name) : null;
  const command = String(call.arguments?.command ?? "").trim();
  // One simple command only: chained, piped or substituted commands are asked every time.
  if (!command || /[;&|`<>]|\$\(|\n/.test(command)) return null;
  const words = command.split(/\s+/).filter((word) => !/^\w+=/.test(word));
  const program = path.basename(words[0] ?? "");
  return /^[\w.+-]+$/.test(program) ? `bash:${program}` : null;
}

/** "Always allow npm commands" / "Always allow phone_location", for the dialog. */
export function alwaysLabel(key) {
  return key.startsWith("bash:") ? `Always allow ${key.slice(5)} commands` : `Always allow ${key}`;
}

export class AlwaysAllow {
  #file;

  constructor(cwd) {
    this.#file = path.join(cwd, ALWAYS_FILE);
  }

  list() {
    try {
      const keys = JSON.parse(fs.readFileSync(this.#file, "utf8")).allow;
      return Array.isArray(keys) ? keys.filter((key) => typeof key === "string").sort() : [];
    } catch {
      return [];
    }
  }

  has(key) {
    return key != null && this.list().includes(key);
  }

  add(key) {
    if (!key || this.has(key)) return;
    this.#write([...this.list(), key]);
  }

  /** Forgets one key; returns whether it was there. */
  remove(key) {
    const keys = this.list();
    if (!keys.includes(key)) return false;
    this.#write(keys.filter((k) => k !== key));
    return true;
  }

  #write(keys) {
    fs.writeFileSync(`${this.#file}.tmp`, JSON.stringify({ allow: keys.sort() }, null, 2) + "\n");
    fs.renameSync(`${this.#file}.tmp`, this.#file);
  }
}
