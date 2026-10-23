import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { AlwaysAllow, alwaysKey, alwaysLabel } from "../always.mjs";
import { approvalExtension, riskOf } from "../approvals.mjs";

const bash = (command) => ({ name: "bash", arguments: { command } });

test("a shell command is remembered whole, and only a plain one that runs no handed-in code", () => {
  assert.equal(alwaysKey(bash("rg TODO src")), "bash:rg TODO src");
  assert.equal(alwaysKey(bash("git  status")), "bash:git status");
  assert.equal(alwaysKey(bash("gh pr list")), "bash:gh pr list");
  for (const command of ["npm test && rm x", "ls | sh", "echo $(id)", "cat a > b", "a; b", "x\ny", "CI=1 git status",
    "/tmp/git status", "./run", "node -e x", "bash script.sh", "python3 x.py", "env FOO=1 ls", "xargs rm", "git -c core.pager=x log",
    "echo 'hi'", "sed s/a/b/ f", "find . -delete", "ls ~", "echo $HOME", "python3.12 x.py", "node22 x.js", "timeout 5 ls",
    "nice ls", "caffeinate ls", "open x.app", "npm test", "npm exec x", "git config core.pager x", "gh pr merge 1",
    "git -C /tmp status", "setsid ls", "uvx ruff", "swift test", "git commit", "git diff", "ls -la", "rg --pre x y", "sort -o f g"]) {
    assert.equal(alwaysKey(bash(command)), null, command);
  }
  assert.equal(alwaysKey({ name: "write", arguments: { path: "a" } }), null);
  assert.equal(alwaysKey({ name: "edit", arguments: { path: "a" } }), null);
  assert.equal(alwaysKey({ name: "phone_location" }), "phone_location");
  assert.equal(alwaysLabel("bash:git status"), "Always allow `git status`");
  assert.equal(alwaysLabel("pap__run"), "Always allow pap__run");
});

test("the list lives in the agent's folder, and the agent can't edit it unasked", () => {
  const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "always-"));
  const always = new AlwaysAllow(cwd);
  always.add("bash:npm test");
  always.add("bash:npm test");
  assert.deepEqual(new AlwaysAllow(cwd).list(), ["bash:npm test"]);
  assert.equal(always.remove("bash:npm test"), true);
  assert.deepEqual(always.list(), []);
  assert.ok(riskOf({ name: "write", arguments: { path: "always-allow.json" } }, { cwd }));
  assert.ok(riskOf({ name: "write", arguments: { path: `${os.homedir()}/.local/state/tavern-durable/flint-1/x` } }, { cwd }));
  assert.ok(riskOf(bash(`cp evil ${os.homedir()}/.local/state/tavern-durable/flint-1/`), { cwd }));
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
  let r = await run(bash("rg TODO src"), always, { allow: true, always: true });
  assert.equal(r.asked[0].always, "Always allow `rg TODO src`");
  assert.deepEqual(always.list(), ["bash:rg TODO src"]);
  r = await run(bash("rg TODO src"), always, { allow: false });
  assert.equal(r.asked.length, 0);
  r = await run(bash("rg FIXME src"), always, { allow: false });
  assert.equal(r.asked.length, 1, "a different command still asks");
  r = await run(bash("rg TODO src"), always, { allow: false });
  assert.equal(r.result, undefined);
  r = await run(bash("rm -rf node_modules"), new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-"))), { allow: true, always: true });
  assert.equal(r.asked[0].always, undefined, "a hard rule offers no always");
});
