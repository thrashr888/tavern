// "Always allow": tools Paul has told an agent to run without asking again, kept in the host's
// state (not the agent's folder), in a place the approvals treat as a secret, so the agent can't
// change it without asking. A shell command is remembered as its exact words, and only for a
// known-safe program; anything else by the tool's name. Only calls the approvals call soft are
// ever remembered or skipped: the hard rules (deletes, root, secrets, force-push) always ask.

import fs from "node:fs";
import path from "node:path";

export const ALWAYS_FILE = "always-allow.json";

/**
 * The programs (and, where it matters, subcommands) whose exact commands may be remembered: ones
 * that read, build or test without running code the agent hands them. Everything else, such as
 * interpreters, wrappers and package-script runners (npm test runs whatever package.json says),
 * asks every time.
 */
const SAFE = {
  ls: true, cat: true, head: true, tail: true, wc: true, pwd: true, date: true, uname: true, which: true, file: true,
  stat: true, du: true, df: true, tree: true, rg: true, grep: true, echo: true, diff: true, sort: true, uniq: true,
  git: ["status", "log", "diff", "show", "branch", "fetch", "pull", "add", "commit", "stash", "switch", "remote", "rev-parse", "blame"],
  gh: ["pr", "issue", "run", "repo", "release"],
  swift: ["build", "test"],
  cargo: ["build", "test", "check", "clippy", "fmt"],
  go: ["build", "test", "vet"],
  docker: ["ps", "images", "logs", "inspect"],
  kubectl: ["get", "describe", "logs"],
};
/** gh subcommands that only read. */
const GH_READS = new Set(["list", "view", "status", "diff", "checks"]);

/**
 * What "always allow" remembers for a call, or null when it can't be remembered safely. A shell
 * command is remembered whole, as its words ("git status", "swift test"): one simple command with
 * a known-safe program (SAFE), no variables, quotes, substitutions or redirects, and no flag that
 * hands it something to run. File writes and edits are never remembered (each one goes somewhere
 * else); other tools are remembered by name.
 */
export function alwaysKey(call) {
  if (call?.name === "write" || call?.name === "edit" || call?.name === "read") return null;
  if (call?.name !== "bash") return call?.name ? String(call.name) : null;
  const command = String(call.arguments?.command ?? "").trim();
  if (!command || command.length > 200 || /[;&|`<>$'"\\\n(){}*?\[\]~!#]/.test(command)) return null;
  const words = command.split(/\s+/);
  const allowed = Object.hasOwn(SAFE, words[0]) ? SAFE[words[0]] : null;
  if (!allowed || (Array.isArray(allowed) && !allowed.includes(words[1]))) return null;
  if (words[0] === "gh" && !GH_READS.has(words[2])) return null;
  if (words.some((word) => /^-(c|e|exec|execdir|ok|C)$|^--(eval|exec|command|config|upload-pack|ext-diff|pre-processor)\b|^-c\S/.test(word))) return null;
  return `bash:${words.join(" ")}`;
}

/** "Always allow `git status`" / "Always allow phone_location", for the dialog. */
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
