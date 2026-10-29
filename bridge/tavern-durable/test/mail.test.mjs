import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { blockedRecipients, recipients } from "../tools/mail.mjs";
import { riskOf } from "../approvals.mjs";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-mail-"));
const allowFile = (allow) => {
  const file = path.join(dir, `allow-${Math.random()}.json`);
  fs.writeFileSync(file, JSON.stringify(allow === undefined ? {} : { allow }));
  return file;
};

test("recipients are read from To and Cc headers", () => {
  assert.deepEqual(recipients("Rook <Rook@Example.com>, quill@example.com"), ["rook@example.com", "quill@example.com"]);
  assert.deepEqual(recipients(undefined), []);
  assert.equal(recipients("not an address"), null);
});

test("with an allow file, mail goes only to the crew; without one, nothing changes", () => {
  const crew = allowFile(["rook@example.com", "tally@example.com"]);
  assert.equal(blockedRecipients("rook@example.com", "Tally <tally@example.com>", crew), null);
  assert.match(blockedRecipients("rook@example.com", "boss@corp.example", crew), /not on the allow list: boss@corp\.example/);
  assert.match(blockedRecipients("someone", undefined, crew), /couldn't be read/);
  assert.match(blockedRecipients("rook@example.com", undefined, allowFile([])), /stopped/, "an empty list is the stop switch");
  assert.match(blockedRecipients("rook@example.com", undefined, allowFile()), /stopped/, "a broken file stops, not opens");
  assert.equal(blockedRecipients("anyone@example.com", undefined, path.join(dir, "missing.json")), null);
});

test("the agent can't change the allow file without asking", () => {
  assert.ok(riskOf({ name: "write", arguments: { path: "~/.config/tavern/mail-allow.json" } }));
  assert.ok(riskOf({ name: "bash", arguments: { command: "echo '{}' > ~/.config/tavern/mail-allow.json" } }));
});

test("importing mail.mjs runs nothing", () => {
  const script = `import(${JSON.stringify(fileURLToPath(new URL("../tools/mail.mjs", import.meta.url)))}).then(() => console.log("ok"))`;
  const result = spawnSync(process.execPath, ["--input-type=module", "-e", script], { encoding: "utf8" });
  assert.equal(result.stdout.trim(), "ok", result.stderr);
});
