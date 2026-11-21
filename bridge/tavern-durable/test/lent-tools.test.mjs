import { test } from "node:test";
import assert from "node:assert/strict";
import { assess } from "../approvals.mjs";
import { LentTools } from "../lent-tools.mjs";

test("a call goes to the client lending the tool and comes back with its answer", async () => {
  const sent = [];
  const lent = new LentTools((socket, record) => sent.push({ socket, record }));
  const phone = { name: "phone" };
  assert.deepEqual(lent.lend(phone, ["phone_location", "nonsense"]), ["phone_location"]);
  const pending = lent.call("phone_location");
  assert.equal(sent[0].socket, phone);
  assert.equal(sent[0].record.tool, "phone_location");
  assert.equal(lent.answer({ name: "other" }, { id: sent[0].record.id, result: {} }), false, "only the asked client answers");
  lent.answer(phone, { id: sent[0].record.id, result: { latitude: 45.5 } });
  assert.deepEqual(await pending, { latitude: 45.5 });
});

test("without a phone, or when it leaves, the call fails in words", async () => {
  const lent = new LentTools(() => {});
  await assert.rejects(lent.call("phone_battery"), /No phone is connected/);
  const phone = {};
  lent.lend(phone, ["phone_battery"]);
  const pending = lent.call("phone_battery");
  lent.drop(phone);
  await assert.rejects(pending, /disconnected/);
  const result = await lent.extension().tools.find((t) => t.name === "phone_battery").execute({});
  assert.equal(result.isError, true);
});

test("phone tools ask Paul first", () => {
  const risk = assess({ name: "phone_location", arguments: {} }, { mcpChanges: new Set(["phone_location"]) });
  assert.deepEqual(risk, { reason: "reads your iPhone's location", hard: false });
});
