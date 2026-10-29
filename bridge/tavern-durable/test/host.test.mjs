import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = (p) => fileURLToPath(new URL(p, import.meta.url));

test("Tavern's RPC subset works against a durable session", async () => {
  const port = 19500 + Math.floor(Math.random() * 400);
  const requestsFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-")), "requests.json");
  const host = spawn(process.execPath, [here("../host.mjs")], {
    env: {
      ...process.env,
      TAVERN_DURABLE_JUDGE: "off",
      TAVERN_DURABLE_RUNTIME: here("./fake-runtime.mjs"),
      TAVERN_DURABLE_PORT: String(port),
      TAVERN_DURABLE_REQUESTS: requestsFile,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  try {
    await new Promise((resolve) => host.stderr.on("data", (d) => String(d).includes("listening") && resolve()));
    const socket = net.connect(port, "127.0.0.1");
    const records = [];
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      let i;
      while ((i = buffer.indexOf("\n")) >= 0) {
        records.push(JSON.parse(buffer.slice(0, i)));
        buffer = buffer.slice(i + 1);
      }
    });
    const send = (record) => socket.write(JSON.stringify(record) + "\n");
    const waitFor = async (predicate) => {
      for (let i = 0; i < 200; i++) {
        const found = records.find(predicate);
        if (found) return found;
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error("timed out");
    };

    send({ id: "t1", type: "get_state" });
    const state = await waitFor((r) => r.id === "t1");
    assert.equal(state.data.sessionId, "durable-1");
    assert.equal(state.data.isStreaming, false);

    send({ id: "t2", type: "get_entries" });
    assert.deepEqual((await waitFor((r) => r.id === "t2")).data.entries.map((e) => e.id), ["e1", "e2"]);

    send({ id: "t3", type: "prompt", message: "list files", requestId: "t3" });
    assert.equal((await waitFor((r) => r.id === "t3")).data.disposition, "started");
    await waitFor((r) => r.type === "agent_settled");

    // The same request resent after a reconnect is answered but not run again.
    send({ id: "t3b", type: "prompt", message: "list files", requestId: "t3" });
    assert.equal((await waitFor((r) => r.id === "t3b")).data.disposition, "duplicate");
    assert.deepEqual(JSON.parse(fs.readFileSync(requestsFile, "utf8")), ["t3"]);
    const types = records.filter((r) => !r.id || !String(r.id).startsWith("t")).map((r) => r.assistantMessageEvent?.type ?? r.type);
    assert.deepEqual(types.filter((t) => t !== "agent_settled").slice(0, 4), ["agent_start", "thinking_delta", "tool_execution_start", "text_delta"]);

    send({ id: "t4", type: "get_entries", since: "e2" });
    assert.deepEqual((await waitFor((r) => r.id === "t4")).data.entries.map((e) => e.message.role), ["user", "assistant"]);

    send({ id: "t5", type: "get_entries", since: "gone" });
    assert.equal((await waitFor((r) => r.id === "t5")).success, false);

    send({ id: "t6", type: "new_session" });
    assert.equal((await waitFor((r) => r.id === "t6")).success, false);
    socket.destroy();
  } finally {
    host.kill("SIGTERM");
  }
});

test("heartbeats run HEARTBEAT.md on schedule and events become follow-ups", async () => {
  const port = 19900 + Math.floor(Math.random() * 90);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-hb-"));
  fs.writeFileSync(path.join(dir, "HEARTBEAT.md"), "Check your mail.");
  const host = spawn(process.execPath, [here("../host.mjs")], {
    env: {
      ...process.env,
      TAVERN_DURABLE_JUDGE: "off",
      TAVERN_DURABLE_RUNTIME: here("./fake-runtime.mjs"),
      TAVERN_DURABLE_PORT: String(port),
      TAVERN_DURABLE_REQUESTS: path.join(dir, "requests.json"),
      TAVERN_DURABLE_HEARTBEAT_FIRST_MS: "150",
      AGENT_CWD: dir,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  try {
    await new Promise((resolve) => host.stderr.on("data", (d) => String(d).includes("listening") && resolve()));
    const socket = net.connect(port, "127.0.0.1");
    const records = [];
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      let i;
      while ((i = buffer.indexOf("\n")) >= 0) {
        records.push(JSON.parse(buffer.slice(0, i)));
        buffer = buffer.slice(i + 1);
      }
    });
    const send = (record) => socket.write(JSON.stringify(record) + "\n");
    const waitFor = async (predicate) => {
      for (let i = 0; i < 300; i++) {
        const found = records.find(predicate);
        if (found) return found;
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error("timed out");
    };
    const userTexts = async (id) => {
      send({ id, type: "get_entries" });
      return (await waitFor((r) => r.id === id)).data.entries.filter((e) => e.message.role === "user").map((e) => e.message.content);
    };

    send({ id: "s1", type: "get_state" });
    assert.equal((await waitFor((r) => r.id === "s1")).data.heartbeat.everyMinutes, 30);
    await waitFor((r) => r.type === "agent_settled");
    assert.ok((await userTexts("g1")).some((t) => t.startsWith("[Heartbeat ") && t.endsWith("Check your mail.")));

    send({ id: "v1", type: "event", source: "mail", text: "Rook wrote: deploy is done", requestId: "v1" });
    assert.equal((await waitFor((r) => r.id === "v1")).success, true);
    send({ id: "v2", type: "event", source: "mail", text: "Rook wrote: deploy is done", requestId: "v1" });
    assert.equal((await waitFor((r) => r.id === "v2")).data.disposition, "duplicate");
    await new Promise((r) => setTimeout(r, 200));
    assert.ok((await userTexts("g2")).includes("[Event from mail]\nRook wrote: deploy is done"));
    socket.destroy();
  } finally {
    host.kill();
  }
});

test("risky tool calls wait for a confirm answer, and a reconnecting client is asked again", async () => {
  const port = 19990 + Math.floor(Math.random() * 9);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-ap-"));
  const host = spawn(process.execPath, [here("../host.mjs")], {
    env: {
      ...process.env,
      TAVERN_DURABLE_JUDGE: "off",
      TAVERN_DURABLE_RUNTIME: here("./fake-runtime.mjs"),
      TAVERN_DURABLE_PORT: String(port),
      TAVERN_DURABLE_REQUESTS: path.join(dir, "requests.json"),
      TAVERN_DURABLE_HEARTBEAT_MINUTES: "0",
      AGENT_CWD: dir,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  const connect = () => {
    const socket = net.connect(port, "127.0.0.1");
    const records = [];
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      let i;
      while ((i = buffer.indexOf("\n")) >= 0) {
        records.push(JSON.parse(buffer.slice(0, i)));
        buffer = buffer.slice(i + 1);
      }
    });
    const send = (record) => socket.write(JSON.stringify(record) + "\n");
    const waitFor = async (predicate) => {
      for (let i = 0; i < 300; i++) {
        const found = records.find(predicate);
        if (found) return found;
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error("timed out");
    };
    return { socket, records, send, waitFor };
  };
  try {
    await new Promise((resolve) => host.stderr.on("data", (d) => String(d).includes("listening") && resolve()));
    const first = connect();
    first.send({ id: "p1", type: "prompt", message: "run: rm -rf build", requestId: "p1" });
    const dialog = await first.waitFor((r) => r.type === "extension_ui_request" && r.method === "confirm");
    assert.match(dialog.title, /^Allow bash\?/);
    assert.equal(dialog.message, "rm -rf build");
    first.send({ id: "s1", type: "get_state" });
    assert.equal((await first.waitFor((r) => r.id === "s1")).data.pendingApprovals, 1);
    first.socket.destroy();

    const second = connect();
    const again = await second.waitFor((r) => r.type === "extension_ui_request" && r.method === "confirm");
    assert.equal(again.id, dialog.id);
    second.send({ type: "extension_ui_response", id: dialog.id, confirmed: false });
    await second.waitFor((r) => r.type === "agent_settled");
    second.send({ id: "g1", type: "get_entries" });
    const last = (await second.waitFor((r) => r.id === "g1")).data.entries.at(-1).message.content[0].text;
    assert.match(last, /^Blocked: Paul declined/);

    second.send({ id: "p2", type: "prompt", message: "run: ls", requestId: "p2" });
    await second.waitFor((r) => r.id === "p2");
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(second.records.filter((r) => r.method === "confirm").length, 1, "safe commands don't ask");
    second.socket.destroy();
  } finally {
    host.kill();
  }
});

test("ask puts a select or input question to Tavern and returns the answer", async () => {
  const port = 19990 + Math.floor(Math.random() * 9);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-ap-"));
  const host = spawn(process.execPath, [here("../host.mjs")], {
    env: {
      ...process.env,
      TAVERN_DURABLE_JUDGE: "off",
      TAVERN_DURABLE_RUNTIME: here("./fake-runtime.mjs"),
      TAVERN_DURABLE_PORT: String(port),
      TAVERN_DURABLE_REQUESTS: path.join(dir, "requests.json"),
      TAVERN_DURABLE_HEARTBEAT_MINUTES: "0",
      AGENT_CWD: dir,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  const connect = () => {
    const socket = net.connect(port, "127.0.0.1");
    const records = [];
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      let i;
      while ((i = buffer.indexOf("\n")) >= 0) {
        records.push(JSON.parse(buffer.slice(0, i)));
        buffer = buffer.slice(i + 1);
      }
    });
    const send = (record) => socket.write(JSON.stringify(record) + "\n");
    const waitFor = async (predicate) => {
      for (let i = 0; i < 300; i++) {
        const found = records.find(predicate);
        if (found) return found;
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error("timed out");
    };
    return { socket, records, send, waitFor };
  };
  try {
    await new Promise((resolve) => host.stderr.on("data", (d) => String(d).includes("listening") && resolve()));
    const first = connect();
    first.send({ id: "p1", type: "prompt", message: `ask: ${JSON.stringify({ question: "Which first?", options: ["Diffs", "Charts"], detail: "Both are ready" })}`, requestId: "p1" });
    const select = await first.waitFor((r) => r.type === "extension_ui_request" && r.method === "select");
    assert.deepEqual([select.title, select.message, select.options], ["Which first?", "Both are ready", ["Diffs", "Charts"]]);
    assert.match(select.id, /^ask-/);
    first.socket.destroy();

    const second = connect();
    const again = await second.waitFor((r) => r.type === "extension_ui_request" && r.method === "select");
    assert.equal(again.id, select.id, "a reconnecting client is asked again");
    second.send({ type: "extension_ui_response", id: select.id, value: "Charts" });
    await second.waitFor((r) => r.type === "agent_settled");
    second.send({ id: "g1", type: "get_entries" });
    assert.equal((await second.waitFor((r) => r.id === "g1")).data.entries.at(-1).message.content[0].text, "Paul answered: Charts");

    second.send({ id: "p2", type: "prompt", message: `ask: ${JSON.stringify({ question: "Name it?", placeholder: "A name" })}`, requestId: "p2" });
    const input = await second.waitFor((r) => r.type === "extension_ui_request" && r.method === "input");
    assert.equal(input.placeholder, "A name");
    second.send({ type: "extension_ui_response", id: input.id, cancelled: true });
    await new Promise((r) => setTimeout(r, 150));
    second.send({ id: "g2", type: "get_entries" });
    assert.equal((await second.waitFor((r) => r.id === "g2")).data.entries.at(-1).message.content[0].text, "Paul dismissed the question without answering.");
    second.socket.destroy();
  } finally {
    host.kill();
  }
});

/** A host with a fake PAP mailbox and the check timer on (beat off); `mail(records)` rewrites the mailbox. */
async function pickupHost(dir, env = {}) {
  const port = 20000 + Math.floor(Math.random() * 500);
  const mailFile = path.join(dir, "mail.json");
  if (!fs.existsSync(mailFile)) fs.writeFileSync(mailFile, JSON.stringify([{ id: "m1", values: { subject: "Old news" } }]));
  fs.mkdirSync(path.join(dir, ".pi"), { recursive: true });
  fs.writeFileSync(path.join(dir, ".pi", "mcp.json"), JSON.stringify({ mcpServers: { pap: { command: process.execPath, args: [here("./fake-pap.mjs")], env: { FAKE_PAP_MAIL: mailFile } } } }));
  fs.writeFileSync(path.join(dir, "heartbeat.json"), JSON.stringify({ checks: [
    { name: "mail", server: "pap", tool: "read", arguments: { connection: "Google", tool: "emails_list", params: {} } },
  ] }));
  const host = spawn(process.execPath, [here("../host.mjs")], {
    env: {
      ...process.env,
      TAVERN_DURABLE_JUDGE: "off",
      TAVERN_DURABLE_RUNTIME: here("./fake-runtime.mjs"),
      TAVERN_DURABLE_PORT: String(port),
      TAVERN_DURABLE_REQUESTS: path.join(dir, "requests.json"),
      TAVERN_DURABLE_STATE: path.join(dir, "state"),
      TAVERN_DURABLE_HEARTBEAT_MINUTES: "0",
      TAVERN_DURABLE_CHECK_MINUTES: "0.005",
      AGENT_CWD: dir,
      ...env,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  const h = { host, port, stderr: "", state: path.join(dir, ".heartbeat-state.json") };
  host.stderr.on("data", (d) => (h.stderr += d));
  h.until = async (predicate) => {
    for (let i = 0; i < 800; i++) {
      if (predicate()) return;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error(`timed out: ${h.stderr.slice(-800)}`);
  };
  h.mail = (records) => fs.writeFileSync(mailFile, JSON.stringify(records));
  h.seen = () => (fs.existsSync(h.state) ? JSON.parse(fs.readFileSync(h.state, "utf8")).checks.mail.seen : []);
  h.rpc = async (command) => {
    const socket = net.connect(port, "127.0.0.1");
    let buffer = "";
    const answer = new Promise((resolve) => socket.on("data", (chunk) => {
      buffer += chunk;
      for (const line of buffer.split("\n").slice(0, -1)) {
        const record = JSON.parse(line);
        if (record.id === command.id) resolve(record);
      }
    }));
    socket.write(JSON.stringify(command) + "\n");
    const record = await answer;
    socket.destroy();
    return record;
  };
  await h.until(() => h.stderr.includes("listening") && h.stderr.includes("checks every"));
  return h;
}

const count = (text, pattern) => (text.match(pattern) ?? []).length;

test("checks run on their own timer, show in get_state, and hand new mail over once, even after a restart", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-pickup-"));
  let h = await pickupHost(dir);
  try {
    await h.until(() => fs.existsSync(h.state)); // the first check only learns what's there
    const state = await h.rpc({ id: "s1", type: "get_state" });
    assert.equal(state.data.heartbeat.everyMinutes, 0, "beat off");
    assert.equal(state.data.heartbeat.checks.everyMinutes, 0.005, "check timer visible with the beat off");
    h.mail([{ id: "m2", values: { subject: "Deploy is done", from: "Rook" } }, { id: "m1" }]);
    await h.until(() => h.stderr.includes("handed over 1: mail:m2"));
    await h.until(() => h.seen().includes("m2"));
    await new Promise((r) => setTimeout(r, 500));
    assert.equal(count(h.stderr, /handed over 1:/g), 1, "handed over once");
  } finally {
    h.host.kill();
  }
  // A restart reads the saved state: nothing is handed over again.
  h = await pickupHost(dir);
  try {
    await new Promise((r) => setTimeout(r, 800));
    assert.equal(count(h.stderr, /handing over/g), 0, h.stderr);
  } finally {
    h.host.kill();
  }
});

test("new mail is handed over while the agent is busy, not skipped", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-busy-"));
  const h = await pickupHost(dir, { FAKE_RUNTIME_STEP_MS: "600" });
  try {
    await h.until(() => fs.existsSync(h.state));
    const started = await h.rpc({ id: "p1", type: "prompt", message: "long task", requestId: "p1" });
    assert.equal(started.data.disposition, "started");
    h.mail([{ id: "m2", values: { subject: "While busy" } }, { id: "m1" }]);
    await h.until(() => h.stderr.includes("handing over 1 (agent busy, queued): mail:m2"));
    await h.until(() => h.seen().includes("m2"));
  } finally {
    h.host.kill();
  }
});

test("a failed hand-off leaves the mail unseen, and the next check hands it over", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-fail-"));
  const h = await pickupHost(dir, { FAKE_RUNTIME_FAIL: "Retry me" });
  try {
    await h.until(() => fs.existsSync(h.state));
    h.mail([{ id: "m2", values: { subject: "Retry me" } }, { id: "m1" }]);
    await h.until(() => h.stderr.includes("checks failed: submit failed"));
    assert.ok(!h.seen().includes("m2"), "not marked seen after the failure");
    await h.until(() => h.stderr.includes("handed over 1: mail:m2"));
    await h.until(() => h.seen().includes("m2"));
  } finally {
    h.host.kill();
  }
});

test("an empty event is refused without using up its request id", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-event-"));
  const h = await pickupHost(dir);
  try {
    assert.equal((await h.rpc({ id: "x1", type: "event", source: "mail", text: " ", requestId: "ev1" })).success, false);
    const ok = await h.rpc({ id: "x2", type: "event", source: "mail", text: "Rook wrote", requestId: "ev1" });
    assert.equal(ok.success, true);
    assert.notEqual(ok.data.disposition, "duplicate");
  } finally {
    h.host.kill();
  }
});
