// A stand-in for the Personal Agent Proxy over stdio: list_connections, and read returning
// emails from FAKE_PAP_MAIL (a JSON file, so a test can add mail between checks).
import fs from "node:fs";
import readline from "node:readline";

const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
const text = (value) => ({ content: [{ type: "text", text: JSON.stringify(value) }] });
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const { id, method, params } = JSON.parse(line);
  if (id == null) return;
  if (method === "initialize") return reply(id, { protocolVersion: params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "pap" } });
  if (method === "tools/list") return reply(id, { tools: [
    { name: "list_connections", inputSchema: { type: "object" }, annotations: { readOnlyHint: true } },
    { name: "read", inputSchema: { type: "object" }, annotations: { readOnlyHint: true } },
  ] });
  if (method === "tools/call" && params.name === "list_connections")
    return reply(id, text({ connections: [{ connection: "cmvh8sg47001fra01oukv8tvd", integration: "Google" }] }));
  if (method === "tools/call" && params.name === "read") {
    if (params.arguments.connection !== "cmvh8sg47001fra01oukv8tvd") return reply(id, { isError: true, ...text({ error: "bad connection" }) });
    const mail = JSON.parse(fs.readFileSync(process.env.FAKE_PAP_MAIL, "utf8"));
    return reply(id, text({ records: mail }));
  }
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: "no" } }) + "\n");
});
