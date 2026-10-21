// Approvals: a Pi Durable `beforeTool` hook that pauses risky tool calls until Paul answers in
// Tavern. The answer is stored as a memo of the tool task, so a host restart while waiting asks
// again (same dialog id) and a restart after answering doesn't ask twice.
//
// Which calls are risky is decided here, by rules over the call's arguments. TAVERN_DURABLE_APPROVALS
// picks the policy: "risky" (default), "all" (every bash, write and edit), or "off".
//
// The rules catch mistakes and prompt-injected requests, not a model set on getting around them:
// a shell can always spell a command another way. "all" is the setting for an agent you don't trust.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = os.homedir();

/** Shell commands that delete, rewrite history, escalate, reach secrets, or change the machine. */
const RISKY_COMMANDS = [
  [/\brm\s+(-\w*\s+)*-\w*[rf]/, "deletes files recursively or forcibly"],
  [/\bsudo\b|\bdoas\b/, "runs as root"],
  [/\bgit\s+push\b[^|;&]*(--force\b|-f\b|--mirror\b|--delete\b|\s:\S)/, "force-pushes or deletes a remote branch"],
  [/\bgit\s+(reset\s+--hard|clean\s+-\w*f|branch\s+-D|checkout\s+--\s|restore\b)/, "discards local work"],
  [/(^|[;&|(]\s*)(env|printenv|set|export\s+-p)\s*($|[;&|>)])/, "prints environment variables, which may hold keys"],
  [/\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/, "runs a downloaded script"],
  [/\b(mkfs|diskutil|fdisk|dd\s+if=)/, "writes to disks"],
  [/\bchmod\s+-R|\bchown\s+-R/, "changes permissions recursively"],
  [/\bdocker\s+(rm|rmi|volume\s+rm|system\s+prune|compose\s+down\s+-v)\b/, "deletes containers, images or volumes"],
  [/\b(launchctl|systemctl|crontab)\b/, "changes services or schedules"],
  [/\b(kill|killall|pkill)\b/, "stops processes"],
  [/\bshutdown\b|\breboot\b/, "restarts the machine"],
  // The host's own socket: answering its approval dialog from a tool would approve itself.
  [/\b(nc|ncat|netcat|socat|telnet)\b|\/dev\/(tcp|udp)\/|\b1901\d\b/, "opens a raw connection, possibly to this agent's host"],
  [/\bgh\s+(repo\s+(delete|edit)|release\s+delete|secret\b|api\s+-X\s*(DELETE|PUT|PATCH))/i, "changes GitHub settings or deletes"],
  [/\bsecurity\s+(find|dump|delete)-/, "reads or deletes keychain items"],
];

/** Paths that hold keys and credentials, or change how the machine or the agent runs. */
const SECRET_PATHS = [
  /(^|\/)\.env(\.|$)/,
  /(^|\/)\.ssh(\/|$)/,
  /(^|\/)\.(zshrc|zprofile|bashrc|bash_profile|profile|netrc|npmrc|pypirc)$/,
  /(^|\/)\.aws(\/|$)|(^|\/)\.config\/gcloud(\/|$)|(^|\/)\.kube\/config$/,
  /(^|\/)\.pi\/agent\/(auth|models)\.json$/,
  /(^|\/)\.docker\/config\.json$/,
  /(^|\/)(credentials|secrets?)(\.\w+)?$/i,
  /\.(pem|key|p12|keychain(-db)?)$/,
  /(^|\/)Library\/LaunchAgents(\/|$)/,
  // Heartbeat checks run without asking, so changing what they call needs Paul.
  /(^|\/)\.?heartbeat(-state)?\.json$/i, // any case: macOS paths ignore it
];

/**
 * Every place the tool might open: the raw path, lexical ".." first then symlinks (what Node's
 * path.resolve does), and symlinks first then ".." (what the kernel does). Any one matching a
 * secret path counts. A path that can't be checked (permissions, loops) comes back as null.
 */
function resolvePaths(file, cwd) {
  const text = String(file ?? "");
  const expanded = text === "~" ? HOME : text.startsWith("~/") ? path.join(HOME, text.slice(2)) : text;
  const absolute = expanded.startsWith("/") ? expanded : `${cwd}/${expanded}`;
  const lexical = path.resolve(absolute);
  return [text, lexical, walk(lexical), walk(absolute)];
}

/**
 * The path the OS would open: one component at a time, following symlinks (dangling ones too)
 * before applying "..", as the kernel does. Past the first missing component it's lexical.
 */
function walk(file, depth = 0) {
  let current = "/";
  const parts = file.split("/").filter((part) => part && part !== ".");
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part === "..") {
      current = path.dirname(current);
      continue;
    }
    const next = path.join(current, part);
    let stat;
    try {
      stat = fs.lstatSync(next);
    } catch (error) {
      if (error?.code !== "ENOENT") return null;
      return path.join(next, ...parts.slice(i + 1));
    }
    if (stat.isSymbolicLink()) {
      if (depth >= 40) return null;
      const target = fs.readlinkSync(next);
      const rest = parts.slice(i + 1).join("/");
      return walk(`${target.startsWith("/") ? target : `${current}/${target}`}${rest ? `/${rest}` : ""}`, depth + 1);
    }
    current = next;
  }
  return current;
}

/** Why this call needs Paul, or null when it can run. */
export function riskOf(call, { policy = "risky", cwd = process.cwd(), mcpChanges } = {}) {
  if (policy === "off") return null;
  const args = call?.arguments ?? {};
  switch (call?.name) {
    case "bash": {
      const command = String(args.command ?? "");
      if (policy === "all") return "runs a shell command";
      // Secrets named on the command line count too (cat ~/.zshrc, grep KEY .env).
      for (const [pattern, reason] of RISKY_COMMANDS) if (pattern.test(command)) return reason;
      const secret = command.split(/[\s'"=<>|;&()]+/).find((word) => word && SECRET_PATHS.some((pattern) => pattern.test(word)));
      if (secret) return `touches ${secret.slice(0, 120)}, which may hold keys`;
      return null;
    }
    case "read":
    case "write":
    case "edit": {
      const files = resolvePaths(args.path, cwd);
      if (files.includes(null)) return `${call.name === "read" ? "reads" : "changes"} a path that couldn't be checked`;
      if (files.some((file) => SECRET_PATHS.some((pattern) => pattern.test(file)))) return `${call.name === "read" ? "reads" : "changes"} a file that may hold keys`;
      if (policy === "all" && call.name !== "read") return "changes a file";
      return null;
    }
    default:
      // MCP tools that aren't read-only (see mcp.mjs) change something on their server.
      if (mcpChanges?.has(call?.name)) return `runs ${call.name.replace("__", "'s ")}, which can change things`;
      return null;
  }
}

/** The dialog Tavern shows: a title and the call in full. */
export function describe(call, reason) {
  const args = call?.arguments ?? {};
  const detail =
    call?.name === "bash" ? String(args.command ?? "")
    : "path" in args ? `${call.name} ${String(args.path ?? "")}`.trim()
    : `${call?.name ?? "tool"} ${JSON.stringify(args)}`;
  return { title: `Allow ${call?.name ?? "tool"}? It ${reason}.`, message: detail.slice(0, 4000) };
}

/**
 * Open questions, oldest first. Tavern shows one dialog at a time, so only the oldest is sent;
 * answering it sends the next. `onChange` gets the dialog to show (or null).
 */
export class Approvals {
  #pending = new Map(); // id -> { dialog, resolve }
  #onChange;

  constructor(onChange = () => {}) {
    this.#onChange = onChange;
  }

  /** Waits for Paul's answer to `dialog` (id is stable across restarts: the tool task id). */
  ask(dialog, signal) {
    const existing = this.#pending.get(dialog.id);
    if (existing) return existing.promise;
    let resolve;
    const promise = new Promise((r) => (resolve = r));
    this.#pending.set(dialog.id, { dialog, resolve, promise });
    signal?.addEventListener("abort", () => this.answer(dialog.id, false, "aborted"), { once: true });
    if (this.#pending.size === 1) this.#onChange(this.current());
    return promise;
  }

  /** Settles a question; returns false for an unknown id. */
  answer(id, allow, note) {
    const entry = this.#pending.get(id);
    if (!entry) return false;
    const wasCurrent = this.current()?.id === id;
    this.#pending.delete(id);
    entry.resolve({ allow: allow === true, ...(note ? { note } : {}) });
    if (wasCurrent) this.#onChange(this.current());
    return true;
  }

  /** The dialog to show now. */
  current() {
    const first = this.#pending.values().next().value;
    return first ? first.dialog : null;
  }

  get size() {
    return this.#pending.size;
  }
}

/** The Pi Durable extension: a `beforeTool` hook for the built-in tool task (`pi.tool`). */
export function approvalExtension(approvals, options) {
  return {
    name: "tavern-approvals",
    hooks: [
      {
        task: "pi.tool",
        handlers: {
          async beforeTool(call, api, context) {
            const reason = riskOf(call, options);
            if (!reason) return undefined;
            let decision = await api.memo("tavern.approval", context);
            if (decision === undefined) {
              const answer = await approvals.ask({ id: `approval-${api.taskId}`, ...describe(call, reason) }, context?.abortSignal);
              decision = await api.memo("tavern.approval", answer, context);
            }
            if (decision.allow) return undefined;
            return { block: decision.note === "aborted" ? "the turn was aborted" : "Paul declined this. Ask before trying it another way." };
          },
        },
      },
    ],
  };
}
