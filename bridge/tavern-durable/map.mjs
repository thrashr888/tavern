// Maps a Pi Durable view onto the Pi RPC shapes Tavern already speaks.
//
// Pi Durable exposes its state as a view (conversation entries plus mounted documents such as
// `pi.live`), not as RPC. These functions are the only place that knows its field names, and they
// read defensively: Pi Durable is experimental and its shapes change between releases. When a
// release moves a field, fix it here and add a fixture to test/map.test.mjs.

/** The first object along `paths` that looks like a pi-ai message (has a `role`). */
function findMessage(entry) {
  // Pi Durable 1.0 keeps an entry's model messages in `model` (EntryRecord.model[0]).
  const candidates = [entry?.model?.[0], entry, entry?.message, entry?.value, entry?.value?.message, entry?.data, entry?.data?.message];
  return candidates.find((c) => c && typeof c === "object" && typeof c.role === "string");
}

function isoTime(value) {
  if (value == null) return undefined;
  if (typeof value === "number") return new Date(value).toISOString();
  if (typeof value === "string") return value;
  return undefined;
}

/** Durable transcript entries, oldest first, whatever the view calls them. */
export function entriesOf(view) {
  const conversation = view?.conversation ?? view;
  const entries = conversation?.entries ?? conversation?.transcript ?? [];
  return Array.isArray(entries) ? entries : [];
}

/** One durable entry as a Pi session entry (`get_entries` shape), or null to skip it. */
export function toPiEntry(entry, index) {
  const id = String(entry?.id ?? entry?.entryId ?? entry?.key ?? index);
  const kind = String(entry?.type ?? entry?.kind ?? "");
  const message = findMessage(entry);
  const timestamp = isoTime(entry?.timestamp ?? entry?.createdAt ?? entry?.at ?? message?.timestamp);
  if (message) {
    return { type: "message", id, timestamp, message };
  }
  if (kind.includes("compaction")) {
    return { type: "compaction", id, timestamp };
  }
  if (kind.includes("model")) {
    const model = entry?.model ?? entry?.value?.model ?? {};
    return { type: "model_change", id, timestamp, provider: model.provider, modelId: model.modelId };
  }
  return null;
}

export function piEntries(view) {
  return entriesOf(view)
    .map((entry, index) => toPiEntry(entry, index))
    .filter(Boolean);
}

function blocks(message) {
  const content = message?.content;
  if (typeof content === "string") return [{ type: "text", text: content }];
  return Array.isArray(content) ? content : [];
}

/**
 * The turn in progress: busy flag, streamed text and thinking, and running tools.
 * Reads the `pi.live` document (`generation.message` is the partial answer).
 */
export function liveOf(view) {
  const conversation = view?.conversation ?? view;
  const docs = conversation?.docs ?? {};
  const live = docs["pi.live"] ?? {};
  const generation = live.generation ?? null;
  const message = generation?.message ?? generation ?? null;
  const parts = blocks(message);
  const text = parts.filter((b) => b.type === "text").map((b) => b.text ?? "").join("");
  const thinking = parts.filter((b) => b.type === "thinking").map((b) => b.thinking ?? "").join("");

  const rawTools = live.tools ?? live.runningTools ?? live.toolCalls ?? [];
  const toolList = Array.isArray(rawTools) ? rawTools : Object.values(rawTools);
  const tools = toolList
    .filter((t) => t && (t.status == null || t.status === "running"))
    .map((t) => ({
      id: String(t.id ?? t.toolCallId ?? t.callId ?? ""),
      name: String(t.name ?? t.toolName ?? "tool"),
      args: t.arguments ?? t.args ?? {},
    }));

  const busy = Boolean(live.busy ?? live.running ?? live.run ?? generation ?? tools.length > 0);
  return { busy, text, thinking, tools };
}

/**
 * Pi RPC events that take a client from `before` to `after` (both from `liveOf`), plus whether
 * new entries were committed. Mirrors what `pi --mode rpc` emits, so Tavern's session code works
 * unchanged.
 */
export function eventsBetween(before, after, entriesGrew) {
  const events = [];
  if (!before.busy && after.busy) events.push({ type: "agent_start" });

  const thinkingDelta = after.thinking.startsWith(before.thinking) ? after.thinking.slice(before.thinking.length) : after.thinking;
  if (thinkingDelta) events.push(update("thinking_delta", thinkingDelta));
  const textDelta = after.text.startsWith(before.text) ? after.text.slice(before.text.length) : after.text;
  if (textDelta) events.push(update("text_delta", textDelta));

  const was = new Map(before.tools.map((t) => [t.id, t]));
  const now = new Map(after.tools.map((t) => [t.id, t]));
  for (const [id, tool] of now) {
    if (!was.has(id)) events.push({ type: "tool_execution_start", toolCallId: id, toolName: tool.name, args: tool.args });
  }
  for (const [id, tool] of was) {
    if (!now.has(id)) events.push({ type: "tool_execution_end", toolCallId: id, toolName: tool.name, isError: false });
  }

  // Only settled means "turn done" to Tavern; it then pulls committed entries with get_entries.
  if ((before.busy && !after.busy) || (!after.busy && entriesGrew)) events.push({ type: "agent_settled" });
  return events;
}

function update(type, delta) {
  return { type: "message_update", assistantMessageEvent: { type, delta } };
}

/** Entries after `since`, or null when `since` is unknown (Tavern then resyncs from scratch). */
export function entriesSince(entries, since) {
  if (since == null) return entries;
  const index = entries.findIndex((e) => e.id === since);
  return index < 0 ? null : entries.slice(index + 1);
}

/** The agent's model and thinking level for `get_state`, from the `pi.agent` document (ModelRef). */
export function agentStateOf(view) {
  const conversation = view?.conversation ?? view;
  const agent = conversation?.docs?.["pi.agent"] ?? {};
  const ref = agent.model;
  const model = ref && ref.modelId ? { provider: ref.provider, id: ref.modelId, modelId: ref.modelId } : undefined;
  return { model, thinkingLevel: agent.thinkingLevel };
}

/** Total tokens and cost so far, from the `pi.usage` document (models and tools combined). */
export function usageOf(view) {
  const doc = (view?.conversation ?? view)?.docs?.["pi.usage"];
  if (!doc) return null;
  const total = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
  for (const usage of [...Object.values(doc.models ?? {}), ...Object.values(doc.tools ?? {})]) {
    total.input += Number(usage?.input ?? 0);
    total.output += Number(usage?.output ?? 0);
    total.cacheRead += Number(usage?.cacheRead ?? 0);
    total.cacheWrite += Number(usage?.cacheWrite ?? 0);
    total.cost += Number(usage?.cost?.total ?? 0);
  }
  return total;
}
