// A stand-in Pi Durable runtime for screenshots: a fixed transcript from DEMO_TRANSCRIPT (JSON
// entries), a model and spend, and, when DEMO_APPROVAL is set, a tool call waiting on approval.
import fs from "node:fs";

export async function openDurable({ cwd, extensions = [] }) {
  const listeners = new Set();
  const entries = JSON.parse(fs.readFileSync(process.env.DEMO_TRANSCRIPT, "utf8"));
  // Recorded times shift so the last entry is a few minutes old.
  const shift = Date.now() - 4 * 60_000 - (entries.at(-1)?.timestamp ?? Date.now());
  for (const entry of entries) entry.timestamp += shift;
  const docs = {
    "pi.live": {},
    "pi.agent": { model: { provider: "anthropic", modelId: process.env.DEMO_MODEL ?? "claude-sonnet-4-6" } },
    "pi.usage": { models: { main: { input: 182000, output: 24000, cost: { total: Number(process.env.DEMO_COST ?? 1.42) } } } },
  };
  const current = () => ({ session: { id: `demo-${process.env.DEMO_NAME ?? "agent"}`, cwd }, conversation: { entries, docs }, notices: [] });
  if (process.env.DEMO_APPROVAL) {
    docs["pi.live"] = { generation: { message: { role: "assistant", content: [] } } };
    const call = { id: "demo-call", name: "bash", arguments: { command: process.env.DEMO_APPROVAL } };
    const api = { taskId: "demo", memo: async (_name, ...rest) => (rest.length === 2 ? rest[0] : undefined) };
    setTimeout(async () => {
      for (const extension of extensions) for (const hook of extension.hooks ?? []) await hook.handlers.beforeTool?.(call, api, {});
    }, 500);
  }
  return {
    view: { current, subscribe: (l) => (listeners.add(l), () => listeners.delete(l)) },
    controller: { async submit() {}, async abort() {}, async compact() {} },
    settings: {},
    async close() {},
  };
}
