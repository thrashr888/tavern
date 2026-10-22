// A demo agent for trying the iPhone app safely: a stand-in for Pi Durable's openDurable() that
// answers each message with a short turn, streamed a few words at a time. It thinks, runs a
// tool step, then replies in Markdown. A message with "delete", "clean" or "approve" in it asks
// for an approval first (through the host's real approval hook) and says what happened.
// Nothing runs: the tool calls are pretend. Used by scripts/phone.sh on port 19614.
export async function openDurable({ cwd, extensions = [] }) {
  const listeners = new Set();
  const now = Date.now();
  let entries = [
    { id: "d1", timestamp: now - 600_000, message: { role: "user", content: "What can you do?" } },
    { id: "d2", timestamp: now - 590_000, message: { role: "assistant", content: [{ type: "text", text: "I'm **Demo**, a pretend agent for trying Tavern on your phone.\n\n- Send me anything and I'll stream a reply.\n- Ask me to *delete* or *clean* something and I'll ask for your approval first.\n\nNothing I do touches a real machine." }] } },
  ];
  let live = {};
  let next = 3;
  const memos = new Map();
  const current = () => ({
    session: { id: "demo-phone", cwd },
    conversation: { entries, docs: { "pi.live": live, "pi.agent": { model: { provider: "anthropic", modelId: "claude-sonnet-4-6" } } } },
    notices: [],
  });
  const emit = () => setImmediate(() => listeners.forEach((l) => l()));
  const step = (ms) => new Promise((r) => setTimeout(r, ms));
  const assistant = (content) => ({ role: "assistant", content });

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
        if (decision?.block) return { blocked: decision.block };
      }
    }
    return { blocked: null };
  }

  async function stream(thinking, text) {
    const words = text.split(/(\s+)/);
    let shown = "";
    for (let i = 0; i < words.length; i += 4) {
      shown += words.slice(i, i + 4).join("");
      live = { generation: { message: assistant([{ type: "thinking", thinking }, { type: "text", text: shown }]) } };
      emit();
      await step(120);
    }
  }

  return {
    view: { current, subscribe: (l) => (listeners.add(l), () => listeners.delete(l)) },
    controller: {
      async submit(text) {
        const asked = String(text ?? "");
        const callID = `call-${next}`;
        entries = [...entries, { id: `d${next++}`, timestamp: Date.now(), message: { role: "user", content: asked } }];
        const thinking = "Let me look at the workspace first.";
        live = { generation: { message: assistant([{ type: "thinking", thinking }]) } };
        emit(); await step(700);

        // A tool step: list the files (pretend).
        const list = { id: `${callID}-ls`, name: "bash", arguments: { command: "ls ~/projects/demo" } };
        live = { generation: { message: assistant([{ type: "thinking", thinking }]) }, tools: [list] };
        emit(); await step(1200);
        entries = [...entries,
          { id: `d${next++}`, timestamp: Date.now(), message: assistant([{ type: "thinking", thinking }, { type: "toolCall", ...list }]) },
          { id: `d${next++}`, timestamp: Date.now(), message: { role: "toolResult", toolCallId: list.id, toolName: "bash", content: [{ type: "text", text: "README.md\nbuild/\nsrc/" }], isError: false } },
        ];
        live = {};
        emit(); await step(300);

        let reply;
        if (/delete|clean|approve/i.test(asked)) {
          const risky = { id: `${callID}-rm`, name: "bash", arguments: { command: "rm -rf ~/projects/demo/build" } };
          live = { tools: [risky] };
          emit();
          const { blocked } = await beforeTool(risky, `task-${callID}`);
          entries = [...entries,
            { id: `d${next++}`, timestamp: Date.now(), message: assistant([{ type: "toolCall", ...risky }]) },
            { id: `d${next++}`, timestamp: Date.now(), message: { role: "toolResult", toolCallId: risky.id, toolName: "bash", content: [{ type: "text", text: blocked ? `Blocked: ${blocked}` : "removed build/" }], isError: Boolean(blocked) } },
          ];
          live = {};
          emit(); await step(300);
          reply = blocked
            ? "You said no, so I left `build/` alone. Nothing changed."
            : "Done: I removed `build/` (pretend).\n\n```\n$ rm -rf ~/projects/demo/build\n```\n\nThe rest of the project is untouched.";
        } else {
          reply = `You said: *${asked.slice(0, 120)}*\n\nHere's what's in the demo project:\n\n1. **README.md**, the overview\n2. **src/**, the code\n3. **build/**, output I can clean up if you ask\n\nSee https://github.com/thrashr888/tavern for the real thing.`;
        }
        await stream("", reply);
        entries = [...entries, { id: `d${next++}`, timestamp: Date.now(), message: { ...assistant([{ type: "text", text: reply }]), stopReason: "stop" } }];
        live = {};
        emit();
      },
      async abort() { live = {}; emit(); },
      async compact() {},
    },
    settings: {},
    async close() {},
  };
}
