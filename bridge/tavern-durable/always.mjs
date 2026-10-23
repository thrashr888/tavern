// "Always allow": tools Paul has told an agent to run without asking again, kept in the host's
// state next to the session (not the agent's folder), in a file the approvals treat as a secret,
// so the agent can't change it without asking. A shell command is remembered as its exact words,
// anything else by the tool's name. Only calls the approvals call soft are ever remembered or
// skipped: the hard rules (deletes, root, secrets, force-push) always ask.

import fs from "node:fs";
import path from "node:path";

export const ALWAYS_FILE = "always-allow.json";

/** Programs that run whatever code they're given: never remembered. */
const RUNS_CODE = new Set(["sh", "bash", "zsh", "fish", "dash", "ksh", "env", "xargs", "exec", "eval", "command", "nohup", "time",
  "node", "deno", "bun", "npx", "bunx", "pnpx", "python", "python3", "ruby", "perl", "php", "lua", "osascript", "awk", "gawk", "sed",
  "find", "ssh", "sudo", "doas", "su", "script", "watch", "parallel", "make", "just"]);

/**
 * What "always allow" remembers for a call, or null when it can't be remembered safely. A shell
 * command is remembered whole, as its words ("npm test", "git status"): one simple command with a
 * bare program name, no variables, quotes, substitutions or redirects, and not an interpreter or
 * anything else that runs code it's handed. File writes and edits are never remembered (each one
 * goes somewhere else); other tools are remembered by name.
 */
export function alwaysKey(call) {
  if (call?.name === "write" || call?.name === "edit" || call?.name === "read") return null;
  if (call?.name !== "bash") return call?.name ? String(call.name) : null;
  const command = String(call.arguments?.command ?? "").trim();
  if (!command || command.length > 200 || /[;&|`<>$'"\\\n(){}*?\[\]~!#]/.test(command)) return null;
  const words = command.split(/\s+/);
  const program = words[0];
  if (!/^[a-z0-9][\w.+-]*$/i.test(program) || RUNS_CODE.has(program.toLowerCase())) return null;
  if (words.some((word) => /^-(c|e)$|^--(eval|exec|command|config)\b|^-c\S/.test(word))) return null;
  return `bash:${words.join(" ")}`;
}

/** "Always allow `npm test`" / "Always allow phone_location", for the dialog. */
export function alwaysLabel(key) {
  return key.startsWith("bash:") ? `Always allow \`${key.slice(5)}\`` : `Always allow ${key}`;
}

export class AlwaysAllow {
  #file;

  /** `dir`: where the host keeps its state for this agent (next to its request log). */
  constructor(dir) {
    fs.mkdirSync(dir, { recursive: true });
    this.#file = path.join(dir, ALWAYS_FILE);
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
