import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { capabilities, dockerContainers, installedClis } from "../capabilities.mjs";

test("lists the MCP servers, running containers and installed CLIs", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "caps-"));
  for (const name of ["gh", "cider"]) fs.writeFileSync(path.join(dir, name), "", { mode: 0o755 });
  fs.writeFileSync(path.join(dir, "jq"), "", { mode: 0o644 }); // not executable
  assert.deepEqual(installedClis(dir), ["gh", "cider"]);
  const run = (cmd, args, opts, done) => done(null, "web\napi\n\n");
  const caps = await capabilities([{ name: "cider", tools: [1, 2, 3] }, { name: "pap" }], { run, pathList: dir });
  assert.deepEqual(caps, { mcp: [{ name: "cider", tools: 3 }, { name: "pap", tools: 0 }], docker: ["api", "web"], clis: ["gh", "cider"] });
  assert.equal(await dockerContainers({ run: (c, a, o, done) => done(new Error("no docker")) }), null);
});
