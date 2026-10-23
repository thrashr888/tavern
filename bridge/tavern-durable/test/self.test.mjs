import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { riskOf } from "../approvals.mjs";
import { SCHEDULE_FILE, savedMinutes, selfExtension } from "../self.mjs";

function setup(answer) {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "self-"));
  const asked = [];
  const set = [];
  const memos = new Map();
  const ext = selfExtension({
    cwd, name: "Cipher", info: () => ({ model: "m", heartbeat: { everyMinutes: 30 } }), setMinutes: (m) => set.push(m),
    approvals: { ask: async (dialog) => { asked.push(dialog); return answer; } },
  });
  const tool = (name) => ext.tools.find((t) => t.name === name);
  const api = { taskId: "7", memo: async (key, value) => { if (value && typeof value === "object" && "allow" in value) memos.set(key, value); return memos.get(key); } };
  return { cwd, asked, set, tool, api };
}

test("my_info returns the agent's own state", async () => {
  const { tool } = setup();
  const result = await tool("my_info").execute({}, {}, {});
  assert.deepEqual(JSON.parse(result.content[0].text), { model: "m", heartbeat: { everyMinutes: 30 } });
});

test("heartbeat_set changes the schedule only after Paul allows it, and it survives a restart", async () => {
  let s = setup({ allow: true });
  let result = await s.tool("heartbeat_set").execute({ everyMinutes: 15, reason: "busier inbox" }, s.api, {});
  assert.equal(s.asked[0].title, "Let Cipher run its heartbeat every 15 min?");
  assert.equal(s.asked[0].message, "busier inbox");
  assert.deepEqual(s.set, [15]);
  assert.match(result.content[0].text, /every 15 min/);
  assert.match(result.content[0].text, /no HEARTBEAT\.md/, "says beats do nothing without the file");
  assert.equal(savedMinutes(s.cwd, 30), 15);

  s = setup({ allow: false });
  result = await s.tool("heartbeat_set").execute({ everyMinutes: 0 }, s.api, {});
  assert.equal(s.asked[0].title, "Let Cipher pause its heartbeat?");
  assert.deepEqual(s.set, []);
  assert.equal(savedMinutes(s.cwd, 30), 30);

  result = await s.tool("heartbeat_set").execute({ everyMinutes: 5000 }, s.api, {});
  assert.equal(result.isError, true);
});

test("the schedule file is one the agent can't write without asking", () => {
  assert.ok(riskOf({ name: "write", arguments: { path: SCHEDULE_FILE } }, { cwd: "/work" }));
  assert.equal(savedMinutes("/nowhere", 30), 30);
});
