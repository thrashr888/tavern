import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { AlwaysAllow, alwaysKey, alwaysLabel } from "../always.mjs";
import { approvalExtension, riskOf } from "../approvals.mjs";

const bash = (command) => ({ name: "bash", arguments: { command } });

test("a simple command is remembered by its program; chains and pipes never are", () => {
  assert.equal(alwaysKey(bash("npm test")), "bash:npm");
  assert.equal(alwaysKey(bash("CI=1 /usr/bin/git status")), "bash:git");
  for (const command of ["npm test && rm x", "ls | sh", "echo $(id)", "cat a > b", "a; b", "x\ny"]) assert.equal(alwaysKey(bash(command)), null, command);
  assert.equal(alwaysKey({ name: "phone_location" }), "phone_location");
  assert.equal(alwaysLabel("bash:npm"), "Always allow npm commands");
  assert.equal(alwaysLabel("pap__run"), "Always allow pap__run");
});

test("the list lives in the agent's folder, and the agent can't edit it unasked", () => {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "always-"));
  const always = new AlwaysAllow(cwd);
  always.add("bash:npm");
  always.add("bash:npm");
  assert.deepEqual(new AlwaysAllow(cwd).list(), ["bash:npm"]);
  assert.equal(always.remove("bash:npm"), true);
  assert.deepEqual(always.list(), []);
  assert.ok(riskOf({ name: "write", arguments: { path: "always-allow.json" } }, { cwd }));
});

async function run(call, always, answer) {
  const asked = [];
  const memos = new Map();
  const approvals = { ask: async (dialog) => { asked.push(dialog); return answer; } };
  const hook = approvalExtension(approvals, { policy: "all", cwd: "/work", always }).hooks[0].handlers.beforeTool;
  const api = { taskId: "1", memo: async (name, value) => { if (value && typeof value === "object" && "allow" in value) memos.set(name, value); return memos.get(name); } };
  return { result: await hook(call, api, {}), asked };
}

test("always allow skips the question next time; hard rules still ask", async () => {
  const always = new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-")));
  let r = await run(bash("npm test"), always, { allow: true, always: true });
  assert.equal(r.asked[0].always, "Always allow npm commands");
  assert.deepEqual(always.list(), ["bash:npm"]);
  r = await run(bash("npm run build"), always, { allow: false });
  assert.equal(r.asked.length, 0);
  assert.equal(r.result, undefined);
  r = await run(bash("rm -rf node_modules"), new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-"))), { allow: true, always: true });
  assert.equal(r.asked[0].always, undefined, "a hard rule offers no always");
});
