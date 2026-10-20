// A stdio MCP server for tests: one read-only tool with an MCP Apps card, one that changes things.
import readline from "node:readline";

const tools = [
  { name: "weather_current", description: "Weather", inputSchema: { type: "object", properties: { city: { type: "string" } } },
    annotations: { readOnlyHint: true }, _meta: { ui: { resourceUri: "ui://fake/weather" } } },
  { name: "music_pause", description: "Pause", inputSchema: { type: "object", properties: {} } },
];
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const { id, method, params } = JSON.parse(line);
  if (id == null) return;
  if (method === "initialize") reply(id, { protocolVersion: params.protocolVersion, capabilities: { tools: {}, resources: {} }, serverInfo: { name: "fake", version: "1" } });
  else if (method === "tools/list") reply(id, { tools });
  else if (method === "tools/call") reply(id, { content: [], structuredContent: { ok: true, data: { city: params.arguments.city, temperature_c: 15 } } });
  else if (method === "resources/read") reply(id, { contents: [{ uri: params.uri, mimeType: "text/html;profile=mcp-app", text: "<p>card</p>", _meta: { ui: { prefersBorder: true } } }] });
  else process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "no" } }) + "\n");
});
