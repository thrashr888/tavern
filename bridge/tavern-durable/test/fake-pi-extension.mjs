// A loaded standard Pi extension, shaped like Pi's loader output, for the host test. It records
// the lifecycle events it hears in $FAKE_PI_LOG and adds the prompt it saw to the system prompt.
import fs from "node:fs";

export async function loadPiExtensions({ cwd }) {
  const record = (event) => fs.appendFileSync(process.env.FAKE_PI_LOG, JSON.stringify({ type: event.type, reason: event.reason ?? null }) + "\n");
  const handlers = new Map([
    ["session_start", [record]],
    ["agent_end", [record]],
    ["session_compact", [record]],
    ["session_shutdown", [record]],
    ["before_agent_start", [(event) => ({ systemPrompt: `${event.systemPrompt}<memory>for "${event.prompt}" in ${cwd}</memory>` })]],
  ]);
  const remember = {
    name: "remember",
    description: "Remember something.",
    parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
    async execute(_id, params) {
      return { content: [{ type: "text", text: `Remembered: ${params.text}` }], details: { saved: params.text } };
    },
  };
  return {
    extensions: [{ path: "/agents/node_modules/pi-fake-memory/index.ts", handlers, tools: new Map([["remember", { definition: remember }]]) }],
    errors: [],
    runtime: {},
  };
}
