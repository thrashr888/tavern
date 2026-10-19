import { test } from "node:test";
import assert from "node:assert/strict";
import { agentStateOf, entriesSince, eventsBetween, liveOf, piEntries, toPiEntry } from "../map.mjs";

test("entries map to Pi session entries", () => {
  const view = { conversation: { entries: [
    { id: "a", timestamp: 1760500000000, message: { role: "user", content: "hi" } },
    { id: "b", value: { message: { role: "assistant", content: [] } } },
    { id: "c", type: "compaction" },
    { id: "d", type: "label" },
  ] } };
  const entries = piEntries(view);
  assert.deepEqual(entries.map((e) => [e.type, e.id]), [["message", "a"], ["message", "b"], ["compaction", "c"]]);
  assert.equal(entries[0].timestamp, "2025-10-15T03:46:40.000Z");
  assert.equal(toPiEntry({}, 7), null);
});

test("Pi Durable 1.0 entries carry their message in model[0]", () => {
  const view = { conversation: { entries: [
    { id: 4, conversationId: 1, kind: "pi.user", model: [{ role: "user", content: [{ type: "text", text: "hi" }], timestamp: 1760500000000 }] },
    { id: 6, conversationId: 1, kind: "pi.assistant", model: [{ role: "assistant", content: [{ type: "text", text: "hello" }] }], byTaskId: 5 },
    { id: 8, conversationId: 1, kind: "pi.tool-result", model: [{ role: "toolResult", toolName: "bash", content: [] }] },
  ] } };
  const entries = piEntries(view);
  assert.deepEqual(entries.map((e) => [e.id, e.message.role]), [["4", "user"], ["6", "assistant"], ["8", "toolResult"]]);
  assert.equal(entries[0].timestamp, "2025-10-15T03:46:40.000Z");
});

test("entriesSince returns null for an unknown id", () => {
  const entries = [{ id: "a" }, { id: "b" }];
  assert.deepEqual(entriesSince(entries, "a"), [{ id: "b" }]);
  assert.deepEqual(entriesSince(entries, undefined), entries);
  assert.equal(entriesSince(entries, "zzz"), null);
});

test("live state becomes Pi RPC events", () => {
  const idle = liveOf({ conversation: { docs: {} } });
  assert.equal(idle.busy, false);
  const thinking = liveOf({ conversation: { docs: { "pi.live": { generation: { message: { role: "assistant", content: [{ type: "thinking", thinking: "Hmm" }] } } } } } });
  assert.deepEqual(eventsBetween(idle, thinking, false).map((e) => e.assistantMessageEvent?.type ?? e.type), ["agent_start", "thinking_delta"]);

  const tool = { ...thinking, tools: [{ id: "c1", name: "bash", args: { command: "ls" } }] };
  const started = eventsBetween(thinking, tool, false);
  assert.deepEqual(started, [{ type: "tool_execution_start", toolCallId: "c1", toolName: "bash", args: { command: "ls" } }]);

  const text = { ...thinking, text: "Done" };
  assert.deepEqual(eventsBetween(tool, text, false).map((e) => e.assistantMessageEvent?.delta ?? e.type), ["Done", "tool_execution_end"]);
  assert.deepEqual(eventsBetween(text, idle, true).map((e) => e.type), ["agent_settled"]);
});

test("new entries while idle still settle so Tavern syncs", () => {
  const idle = liveOf({});
  assert.deepEqual(eventsBetween(idle, idle, true).map((e) => e.type), ["agent_settled"]);
  assert.deepEqual(eventsBetween(idle, idle, false), []);
});

test("agent state gives get_state its model and thinking level", () => {
  const view = { conversation: { docs: { "pi.agent": { model: { provider: "ollama", modelId: "qwen3.5" }, thinkingLevel: "low" } } } };
  assert.deepEqual(agentStateOf(view), { model: { provider: "ollama", id: "qwen3.5", modelId: "qwen3.5" }, thinkingLevel: "low" });
  assert.deepEqual(agentStateOf({ conversation: { docs: {} } }), { model: undefined, thinkingLevel: undefined });
});

test("usage totals models and tools from pi.usage", async () => {
  const { usageOf } = await import("../map.mjs");
  const view = { conversation: { docs: { "pi.usage": {
    models: { "a/m": { input: 10, output: 5, cacheRead: 2, cacheWrite: 1, cost: { total: 0.5 } } },
    tools: { sub: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: { total: 0.25 } } },
  } } } };
  assert.deepEqual(usageOf(view), { input: 11, output: 6, cacheRead: 2, cacheWrite: 1, cost: 0.75 });
  assert.equal(usageOf({ conversation: { docs: {} } }), null);
});
