import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { RequestLog } from "../requests.mjs";

const tempFile = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), "tavern-requests-")), "requests.json");

test("a request id is claimed once, across restarts", () => {
  const file = tempFile();
  const log = new RequestLog(file);
  assert.equal(log.claim("a"), true);
  assert.equal(log.claim("a"), false);
  assert.equal(new RequestLog(file).claim("a"), false);
  assert.equal(new RequestLog(file).claim("b"), true);
});

test("requests without an id always run", () => {
  const log = new RequestLog(tempFile());
  assert.equal(log.claim(undefined), true);
  assert.equal(log.claim(undefined), true);
});

test("only the newest ids are kept", () => {
  const file = tempFile();
  const log = new RequestLog(file, 2);
  log.claim("a"); log.claim("b"); log.claim("c");
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), ["b", "c"]);
  assert.equal(new RequestLog(file, 2).claim("a"), true);
});

test("an unreadable file starts empty", () => {
  const file = tempFile();
  fs.writeFileSync(file, "not json");
  assert.equal(new RequestLog(file).claim("a"), true);
});
