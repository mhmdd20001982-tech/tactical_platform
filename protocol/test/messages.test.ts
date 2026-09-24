import assert from "node:assert/strict";
import test from "node:test";
import { createMessage, parseMessage, ProtocolError } from "../src/messages";
import { FrameDecoder } from "../src/frame-codec";

test("round trips a location message", () => {
  const message = createMessage(
    "LOCATION",
    "device-1",
    { latitude: 31.95, longitude: 35.91, recorded_at: Date.now() },
    "team-1",
  );
  assert.deepEqual(parseMessage(message), message);
});

test("rejects invalid coordinates", () => {
  assert.throws(
    () =>
      parseMessage({
        v: 1,
        type: "LOCATION",
        id: "m1",
        sender_id: "d1",
        ts: Date.now(),
        team_id: "t1",
        payload: { latitude: 100, longitude: 0, recorded_at: Date.now() },
      }),
    ProtocolError,
  );
});

test("decodes split newline-delimited frames", () => {
  const message = createMessage("PING", "device-1", {});
  const decoder = new FrameDecoder();
  const encoded = `${JSON.stringify(message)}\n`;
  assert.deepEqual(decoder.add(encoded.slice(0, 8)), []);
  assert.deepEqual(decoder.add(encoded.slice(8)), [message]);
});
