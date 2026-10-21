// A stand-in for pi-bundle's "cards" server: no tools of its own here, and card pages to read.
import readline from "node:readline";

const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const { id, method, params } = JSON.parse(line);
  if (id == null) return;
  if (method === "initialize") reply(id, { protocolVersion: params.protocolVersion, capabilities: { tools: {}, resources: {} }, serverInfo: { name: "cards" } });
  else if (method === "tools/list") reply(id, { tools: [] });
  else if (method === "resources/read") reply(id, { contents: [{ uri: params.uri, mimeType: "text/html;profile=mcp-app", text: `<p>${params.uri}</p>` }] });
  else process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "no" } }) + "\n");
});
