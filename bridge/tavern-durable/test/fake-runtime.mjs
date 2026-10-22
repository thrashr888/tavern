// A stand-in for Pi Durable's openDurable(): one conversation that answers each submit with a
// short turn (thinking, a tool call, then text), driven by timers. "run: <command>" sends the
// bash call through the extensions' beforeTool hooks first, as the real tool task does.
// "ask: <json>" runs the extensions' ask tool with those arguments.
export async function openDurable({ cwd, extensions = [] }) {
  const listeners = new Set();
  let entries = [
    { id: "e1", timestamp: 1760500000000, message: { role: "user", content: "hello" } },
    { id: "e2", timestamp: 1760500001000, message: { role: "assistant", content: [{ type: "text", text: "hi" }] } },
  ];
  let live = {};
  let notices = [];
  const current = () => ({ session: { id: "durable-1", cwd }, conversation: { entries, docs: { "pi.live": live } }, notices });
  const emit = () => setImmediate(() => listeners.forEach((l) => l()));
  const step = (ms) => new Promise((r) => setTimeout(r, ms));
  let next = 3;
  const memos = new Map();
  const apiFor = (taskId) => ({
      taskId,
      async memo(name, ...rest) {
        const key = `${taskId}/${name}`;
        if (rest.length === 1) return memos.get(key);
        if (!memos.has(key)) memos.set(key, rest[0]);
        return memos.get(key);
      },
    });
  async function runTool(name, args, taskId) {
    const tool = extensions.flatMap((e) => e.tools ?? []).find((t) => t.name === name);
    const result = await tool.execute(args, apiFor(taskId), { abortSignal: undefined });
    return result.content.map((c) => c.text).join("\n");
  }
  async function beforeTool(call, taskId) {
    const api = {
      taskId,
      async memo(name, ...rest) {
        const key = `${taskId}/${name}`;
        if (rest.length === 1) return memos.get(key);
        if (!memos.has(key)) memos.set(key, rest[0]);
        return memos.get(key);
      },
    };
    for (const extension of extensions) {
      for (const hook of extension.hooks ?? []) {
        if (hook.task !== "pi.tool" || !hook.handlers.beforeTool) continue;
        const decision = await hook.handlers.beforeTool(call, api, { abortSignal: undefined });
        if (decision?.block) return `Blocked: ${decision.block}`;
      }
    }
    return "Done";
  }

  return {
    view: { current, subscribe: (l) => (listeners.add(l), () => listeners.delete(l)) },
    controller: {
      async submit(text) {
        entries = [...entries, { id: `e${next++}`, timestamp: Date.now(), message: { role: "user", content: text } }];
        live = { generation: { message: { role: "assistant", content: [{ type: "thinking", thinking: "Let me" }] } } };
        emit(); await step(20);
        const command = text.startsWith("run: ") ? text.slice(5) : "ls";
        const call = { id: `c${next}`, name: "bash", arguments: { command } };
        live = { generation: live.generation, tools: [call] };
        emit(); await step(20);
        const answer = text.startsWith("ask: ") ? await runTool("ask", JSON.parse(text.slice(5)), `task-${next}`) : await beforeTool(call, `task-${next}`);
        live = { generation: { message: { role: "assistant", content: [{ type: "thinking", thinking: "Let me" }, { type: "text", text: answer }] } } };
        emit(); await step(20);
        entries = [...entries, { id: `e${next++}`, timestamp: Date.now(), message: { role: "assistant", content: [{ type: "text", text: answer }] } }];
        live = {};
        emit();
      },
      async abort() {},
      async compact() { notices = [...notices, { id: "n1", level: "info", message: "Compacted" }]; emit(); },
    },
    settings: {},
    async close() {},
  };
}
