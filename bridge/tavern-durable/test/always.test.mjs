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
  assert.equal(alwaysKey({ name: "phone_location" }), null);
  assert.equal(alwaysLabel("bash:git status"), "Always allow `git status`");
  assert.equal(alwaysLabel("pap__run"), "Always allow pap__run");
});

test("the list lives in host state for the agent, and the agent can't edit it unasked", () => {
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

async function run(call, always, answer, options = {}) {
  const asked = [];
  const memos = new Map();
  const approvals = { ask: async (dialog) => { asked.push(dialog); return answer; } };
  const hook = approvalExtension(approvals, { policy: "all", cwd: "/work", always, ...options }).hooks[0].handlers.beforeTool;
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

test("Git remembers only exact read forms, never mutating or ambiguous operands", () => {
  for (const command of ["git status", "git branch", "git remote", "git rev-parse HEAD"]) {
    assert.equal(alwaysKey(bash(command)), `bash:${command}`);
  }
  for (const command of [
    "git branch new-branch", "git branch new HEAD", "git branch -d old", "git branch --delete old",
    "git branch --list", "git remote add upstream https://example.com/repo.git", "git remote remove origin",
    "git remote rm origin", "git remote rename origin upstream", "git remote set-url origin x",
    "git remote update", "git remote prune origin", "git remote show origin", "git status path",
    "git rev-parse --git-dir", "git rev-parse HEAD other", "git rev-parse", "git -C /tmp branch",
    "git branch new; git status", "git branch new && git status", "git branch $(echo new)",
    "git branch 'new'", 'git branch "new"', "git branch new > log", "git branch new | cat",
    "git status\n", "\ngit status", "git\tstatus", "git status\r", "git status\u0000", "git status\u007f",
  ]) assert.equal(alwaysKey(bash(command)), null, JSON.stringify(command));
  assert.equal(alwaysKey(bash({ toString: () => "git status" })), null);
});

test("old mutating Git grants cannot bypass approval or be remembered again", async () => {
  const always = new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-")));
  for (const command of ["git branch new-branch", "git remote remove origin"]) {
    always.add(`bash:${command}`); // isolated fixture represents a pre-hardening grant
    const r = await run(bash(command), always, { allow: false });
    assert.equal(r.asked.length, 1);
    assert.equal(r.asked[0].always, undefined);
    assert.match(r.result.block, /declined/);
  }
});

test("generic tool grants never bypass approval, even with changed recipients or actions", async () => {
  const always = new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-")));
  always.add("pap__run"); // retain old keys for inspection/revocation, but never use them
  const before = always.list();
  const options = { mcpChanges: new Set(["pap__run"]) };
  for (const args of [{ tool: "emails_send", to: "one@example.com" },
    { tool: "emails_send", to: "different@example.com" }, { tool: "delete_records" }]) {
    const call = { name: "pap__run", arguments: args };
    assert.equal(alwaysKey(call), null);
    const denied = await run(call, always, { allow: false }, options);
    assert.equal(denied.asked.length, 1);
    assert.equal(denied.asked[0].always, undefined);
    assert.match(denied.result.block, /declined/);
    const approved = await run(call, always, { allow: true, always: true }, options);
    assert.equal(approved.asked.length, 1);
    assert.equal(approved.result, undefined, "explicit approval still permits this call");
    assert.deepEqual(always.list(), before, "an unsolicited always flag cannot broaden state");
  }
  const fresh = new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-")));
  await run({ name: "pap__run", arguments: {} }, fresh, { allow: true, always: true }, options);
  assert.deepEqual(fresh.list(), [], "no new tool-name-only grants");
});

test("stored hard-rule keys cannot bypass denial and cannot offer Always", async () => {
  const always = new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-")));
  for (const command of ["cat .env", "rm -rf build", "sudo ls", "git push --force"]) {
    always.add(`bash:${command}`);
    const r = await run(bash(command), always, { allow: false });
    assert.equal(r.asked.length, 1);
    assert.equal(r.asked[0].always, undefined);
    assert.match(r.result.block, /declined/);
  }
});


test("date remembers only the operand-free read form, ignoring legacy clock-setting grants", async () => {
  assert.equal(alwaysKey(bash("date")), "bash:date");
  const always = new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-")));
  // BSD/macOS mmddHHMM[[cc]yy][.ss], GNU MMDDhhmm[[CC]YY][.ss], and formatting operands.
  for (const command of ["date 11111234", "date 1111123426", "date 111112342026",
    "date 111112342026.56", "date 11111234.56", "date +%s", "date --set=2026-11-11", "date -s now"]) {
    assert.equal(alwaysKey(bash(command)), null, command);
    always.add(`bash:${command}`); // isolated fixture only; no date command is executed
    const r = await run(bash(command), always, { allow: false });
    assert.equal(r.asked.length, 1);
    assert.equal(r.asked[0].always, undefined);
    assert.match(r.result.block, /declined/);
  }
  const before = always.list();
  const allowed = await run(bash("date 111112342026.56"), always, { allow: true, always: true });
  assert.equal(allowed.result, undefined, "explicit approval remains available");
  assert.deepEqual(always.list(), before, "legacy grants remain unchanged");
});

test("remembered approval persists for one host-state directory but does not grant another agent", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "always-agent-a-"));
  const first = new AlwaysAllow(dir);
  const call = bash("git status");
  const approved = await run(call, first, { allow: true, always: true });
  assert.equal(approved.asked.length, 1);
  assert.equal(approved.result, undefined);
  assert.deepEqual(first.list(), ["bash:git status"]);

  const reopened = new AlwaysAllow(dir);
  const sameHost = await run(call, reopened, { allow: false });
  assert.equal(sameHost.asked.length, 0, "the same host retains its grant across instances");
  assert.equal(sameHost.result, undefined);

  const second = new AlwaysAllow(fs.mkdtempSync(path.join(os.tmpdir(), "always-agent-b-")));
  const otherHost = await run(call, second, { allow: false });
  assert.equal(otherHost.asked.length, 1, "another agent's state has no inherited grant");
  assert.match(otherHost.result.block, /declined/);
  assert.deepEqual(second.list(), []);
  assert.deepEqual(reopened.list(), ["bash:git status"], "the first host's grant is unchanged");
});
