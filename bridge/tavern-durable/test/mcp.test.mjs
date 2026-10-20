import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { agentToolName, mcpExtension, readCard, startServers } from "../mcp.mjs";
import { riskOf } from "../approvals.mjs";

const here = (p) => fileURLToPath(new URL(p, import.meta.url));

test("MCP servers become agent tools that keep their cards", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-mcp-"));
  fs.mkdirSync(path.join(dir, ".pi"));
  fs.writeFileSync(path.join(dir, ".pi", "mcp.json"), JSON.stringify({
    mcpServers: { fake: { command: process.execPath, args: [here("./fake-mcp.mjs")] }, broken: { command: "/nonexistent/server" } },
  }));
  const servers = await startServers({ cwd: dir });
  try {
    assert.deepEqual(servers.map((s) => s.name), ["fake"], "a server that won't start is skipped");
    const extension = mcpExtension(servers);
    assert.deepEqual(extension.tools.map((t) => t.name), ["fake__weather_current", "fake__music_pause"]);
    assert.deepEqual(extension.tools.map((t) => t.replay), ["safe", "unsafe"]);

    const result = await extension.tools[0].execute({ city: "SF" });
    assert.match(result.content[0].text, /"temperature_c":15/);
    assert.deepEqual(result.details.ui, { server: "fake", resourceUri: "ui://fake/weather", structuredContent: { ok: true, data: { city: "SF", temperature_c: 15 } } });
    assert.equal((await extension.tools[1].execute({})).details.ui, undefined);

    const card = await readCard(servers, "fake", "ui://fake/weather");
    assert.equal(card.html, "<p>card</p>");
    await assert.rejects(readCard(servers, "fake", "ui://fake/other"), /isn't a card/);
    await assert.rejects(readCard(servers, "nope", "ui://fake/weather"), /no MCP server/);

    const mcpChanges = new Set(["fake__music_pause"]);
    assert.ok(riskOf({ name: "fake__music_pause", arguments: {} }, { mcpChanges }));
    assert.equal(riskOf({ name: "fake__weather_current", arguments: {} }, { mcpChanges }), null);
  } finally {
    for (const server of servers) server.close();
  }
});

test("tool names fit model limits", () => {
  assert.equal(agentToolName("cider", "weather.current"), "cider__weather_current");
  assert.equal(agentToolName("x".repeat(40), "y".repeat(40)).length, 64);
});

test("a server that drops starts again, and calls wait for it", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tavern-mcp-"));
  fs.mkdirSync(path.join(dir, ".pi"));
  fs.writeFileSync(path.join(dir, ".pi", "mcp.json"), JSON.stringify({ mcpServers: { fake: { command: process.execPath, args: [here("./fake-mcp.mjs")] } } }));
  const logs = [];
  const [server] = await startServers({ cwd: dir, log: (line) => logs.push(line) });
  try {
    server.crash();
    await new Promise((r) => setTimeout(r, 100));
    const extension = mcpExtension([server]);
    const result = await extension.tools[0].execute({ city: "SF" });
    assert.match(result.content[0].text, /"temperature_c":15/);
    assert.ok(logs.some((l) => /starting again/.test(l)) && logs.some((l) => /is back/.test(l)));
  } finally {
    server.close();
  }
});
