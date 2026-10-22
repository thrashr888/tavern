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
