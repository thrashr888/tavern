import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { extensionName, piExtensionBridge } from "../pi-extensions.mjs";

const here = (p) => fileURLToPath(new URL(p, import.meta.url));

function loaded(handlers = {}, tools = []) {
  return {
    extensions: [{
      path: "/home/flint/.pi/agent/npm/node_modules/@paul/pi-cortex/index.ts",
      handlers: new Map(Object.entries(handlers).map(([type, fn]) => [type, [fn]])),
      tools: new Map(tools.map((definition) => [definition.name, { definition }])),
    }],
    runtime: {},
  };
}

test("names come from the package folder", () => {
  assert.equal(extensionName({ path: "/x/node_modules/@paul/pi-cortex/index.ts" }), "@paul/pi-cortex");
  assert.equal(extensionName({ path: "/x/node_modules/pi-memory/src/index.ts" }), "pi-memory");
  assert.equal(extensionName({ path: "/agents/flint/.pi/extensions/notes/index.ts" }), "notes");
  assert.equal(extensionName({ path: "/agents/flint/.pi/extensions/notes.ts" }), "notes.ts");
});

test("tools run with Pi's signature and come back as durable results", async () => {
  const calls = [];
  const bridge = piExtensionBridge(loaded({}, [{
    name: "cortex_save",
    description: "Save a memory.",
    parameters: { type: "object", properties: {} },
    promptGuidelines: ["Save what you learn."],
    async execute(id, params, signal, onUpdate, ctx) {
      calls.push({ id, params, cwd: ctx.cwd, hasUI: ctx.hasUI });
      return { content: [{ type: "text", text: "saved" }], details: { id: 7, at: new Date(0) } };
    },
  }, {
    name: "broken",
    description: "Throws.",
    parameters: { type: "object", properties: {} },
    async execute() { throw new Error("nope"); },
  }]), { cwd: "/agents/flint" });
  const [save, broken] = bridge.extension.tools;
  assert.equal(save.replay, "unsafe");
  assert.equal(save.guidelines, undefined);
  const result = await save.execute({ text: "hi" }, { callId: "c1" }, {});
  assert.deepEqual(calls, [{ id: "c1", params: { text: "hi" }, cwd: "/agents/flint", hasUI: false }]);
  assert.deepEqual(result, { content: [{ type: "text", text: "saved" }], details: { id: 7, at: "1970-01-01T00:00:00.000Z" }, isError: false });
  assert.deepEqual(await broken.execute({}, {}, {}), { content: [{ type: "text", text: "broken failed: nope" }], isError: true });
  // Guidelines alone are enough for a section.
  assert.equal(await bridge.extension.sections[0].render(), "Tool guidelines:\n- Save what you learn.");
});

test("before_agent_start renders once per prompt", async () => {
  let runs = 0;
  const bridge = piExtensionBridge(loaded({
    before_agent_start: (event) => {
      runs++;
      return { systemPrompt: `${event.systemPrompt}Memory for ${event.prompt}`, message: { content: [{ type: "text", text: "Also this." }] } };
    },
  }), { cwd: "/a" });
  const [section] = bridge.extension.sections;
  bridge.setPrompt("deploy");
  assert.equal(await section.render(), "Memory for deploy\n\nAlso this.");
  assert.equal(await section.render(), "Memory for deploy\n\nAlso this.");
  assert.equal(runs, 1);
  bridge.setPrompt("tests");
  assert.equal(await section.render(), "Memory for tests\n\nAlso this.");
  assert.equal(runs, 2);
});

test("events reach handlers, failures are logged, and pi actions reach the host", async () => {
  const seen = [];
  const logs = [];
  const submitted = [];
  const set = loaded({
    session_start: (event, ctx) => seen.push([event.type, ctx.cwd]),
    session_compact: () => { throw new Error("db locked"); },
  });
  const bridge = piExtensionBridge(set, { cwd: "/a", log: (m) => logs.push(m), submit: (t) => submitted.push(t) });
  await bridge.emit({ type: "session_start", reason: "startup" });
  await bridge.emit({ type: "session_compact" });
  await bridge.emit({ type: "agent_end" });
  assert.deepEqual(seen, [["session_start", "/a"]]);
  assert.deepEqual(logs, ["@paul/pi-cortex session_compact failed: db locked"]);
  set.runtime.sendUserMessage("remember this");
  set.runtime.sendMessage({ content: "quiet" }, {});
  set.runtime.sendMessage({ content: [{ type: "text", text: "loud" }] }, { triggerTurn: true });
  assert.deepEqual(submitted, ["remember this", "loud"]);
  assert.deepEqual(bridge.extension.sections, []);
});

test("the host loads Pi packages: tools, prompt, start, compaction, settle and shutdown", async () => {
  const port = 19400 + Math.floor(Math.random() * 90);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-durable-pi-"));
  const events = path.join(dir, "events.jsonl");
  const host = spawn(process.execPath, [here("../host.mjs")], {
    env: {
      ...process.env,
      TAVERN_DURABLE_RUNTIME: here("./fake-runtime.mjs"),
      TAVERN_DURABLE_PI_LOADER: here("./fake-pi-extension.mjs"),
      TAVERN_DURABLE_PORT: String(port),
      TAVERN_DURABLE_REQUESTS: path.join(dir, "requests.json"),
      TAVERN_DURABLE_HEARTBEAT_MINUTES: "0",
      AGENT_CWD: dir,
      FAKE_PI_LOG: events,
    },
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  host.stderr.on("data", (d) => (stderr += d));
  const exited = new Promise((resolve) => host.on("exit", resolve));
  try {
    for (let i = 0; i < 300 && !stderr.includes("listening"); i++) await new Promise((r) => setTimeout(r, 10));
    assert.match(stderr, /pi extensions: pi-fake-memory/);
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
    const lastAnswer = async (id) => {
      send({ id, type: "get_entries" });
      const entries = (await waitFor((r) => r.id === id)).data.entries;
      return entries.at(-1).message.content[0].text;
    };
    const settled = () => records.filter((r) => r.type === "agent_settled").length;

    send({ id: "p1", type: "prompt", message: "sections", requestId: "p1" });
    for (let i = 0; i < 300 && settled() < 1; i++) await new Promise((r) => setTimeout(r, 10));
    assert.equal(await lastAnswer("g1"), `<memory>for "sections" in ${dir}</memory>`);

    send({ id: "p2", type: "prompt", message: `tool: remember ${JSON.stringify({ text: "pnpm" })}`, requestId: "p2" });
    for (let i = 0; i < 300 && settled() < 2; i++) await new Promise((r) => setTimeout(r, 10));
    assert.equal(await lastAnswer("g2"), "Remembered: pnpm");

    send({ id: "c1", type: "compact" });
    await waitFor((r) => r.id === "c1");
    await new Promise((r) => setTimeout(r, 100));
    socket.destroy();
  } finally {
    host.kill("SIGTERM");
  }
  await exited;
  const types = fs.readFileSync(events, "utf8").trim().split("\n").map((line) => JSON.parse(line).type);
  assert.deepEqual(types, ["session_start", "agent_end", "agent_end", "session_compact", "session_shutdown"]);
});

test("extensions see pi's model registry and the session's model", async () => {
  const registry = { find: (provider, id) => ({ provider, id, api: "anthropic-messages" }) };
  let seen;
  const set = { ...loaded({ session_start: (_event, ctx) => (seen = { model: ctx.model, registry: ctx.modelRegistry }) }), modelRegistry: registry };
  const bridge = piExtensionBridge(set, { cwd: "/a", model: () => ({ provider: "anthropic", id: "claude-opus-5-5" }) });
  await bridge.emit({ type: "session_start" });
  assert.deepEqual(seen.model, { provider: "anthropic", id: "claude-opus-5-5", api: "anthropic-messages" });
  assert.equal(seen.registry, registry);
  const none = piExtensionBridge(loaded({ session_start: (_event, ctx) => (seen = ctx.model) }), { cwd: "/a" });
  await none.emit({ type: "session_start" });
  assert.equal(seen, undefined);
});
