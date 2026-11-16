// Remembers the request ids of recent submits, so a prompt Tavern resends after a dropped
// connection runs once. Pi Durable dedupes `requestId` itself, but the v1.0/v1.1 coding-agent
// wrapper (openDurable's controller.submit) doesn't pass one through, so the host keeps its own.
//
// Kept in a small JSON file next to the session (newest last, capped), written before the submit
// starts: at most once. A crash between the write and the submit, or a submit that fails, loses that
// prompt rather than running it twice; a resend then answers "duplicate". Heartbeat checks don't use
// this log: they mark mail seen only after handing it over (at least once, see host.mjs).
// If the file can't be written, dedup lasts only until a restart; that's logged, not fatal.

import fs from "node:fs";
import path from "node:path";

export class RequestLog {
  constructor(file, limit = 200) {
    this.file = file;
    this.limit = limit;
    this.ids = [];
    try {
      const saved = JSON.parse(fs.readFileSync(file, "utf8"));
      if (Array.isArray(saved)) this.ids = saved.filter((id) => typeof id === "string").slice(-limit);
    } catch {
      // Missing or unreadable: start empty.
    }
    this.seen = new Set(this.ids);
  }

  /** True the first time `id` is claimed; false for a repeat. No id always claims. */
  claim(id) {
    if (id == null || id === "") return true;
    const key = String(id);
    if (this.seen.has(key)) return false;
    this.ids.push(key);
    this.seen.add(key);
    while (this.ids.length > this.limit) this.seen.delete(this.ids.shift());
    this.save();
    return true;
  }

  save() {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const temp = `${this.file}.tmp`;
      fs.writeFileSync(temp, JSON.stringify(this.ids));
      fs.renameSync(temp, this.file);
    } catch (error) {
      // Dedup is best effort; never block a prompt on it, but say so.
      process.stderr.write(`request log not saved (${this.file}): ${error?.message ?? error}\n`);
    }
  }
}
