import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createMessage } from "@tactical-platform/protocol";
import {
  DEFAULT_HISTORY_RETENTION_MS,
  MessageStore,
} from "../src/message-store";

test("persists team history across restarts and keeps only latest entity state", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "tactical-store-"));
  try {
    let now = 1_800_000_000_000;
    const store = new MessageStore(directory, DEFAULT_HISTORY_RETENTION_MS, () => now);
    store.record(createMessage("LOCATION", "device-1", {
      latitude: 31,
      longitude: 35,
      recorded_at: now,
    }, "team-a"));
    store.record(createMessage("LOCATION", "device-1", {
      latitude: 32,
      longitude: 36,
      recorded_at: now + 1,
    }, "team-a"));
    store.record(createMessage("CHAT", "device-2", { text: "hello" }, "team-a"));
    store.record(createMessage("CHAT", "device-3", { text: "private team" }, "team-b"));
    store.record(createMessage("POINT", "device-2", {
      point_id: "point-1",
      name: "Old name",
      latitude: 31,
      longitude: 35,
    }, "team-a"));
    store.record(createMessage("POINT", "device-2", {
      point_id: "point-1",
      name: "Updated name",
      latitude: 32,
      longitude: 36,
    }, "team-a"));
    store.record(createMessage("SOS", "device-2", {
      event_id: "sos-1",
      status: "ACTIVE",
      latitude: 31,
      longitude: 35,
    }, "team-a"));
    store.record(createMessage("SOS", "device-2", {
      event_id: "sos-1",
      status: "CANCELLED",
      latitude: 31,
      longitude: 35,
    }, "team-a"));

    const restored = new MessageStore(directory, DEFAULT_HISTORY_RETENTION_MS, () => now);
    const history = restored.getTeamHistory("team-a");
    assert.deepEqual(history.map((message) => message.type), [
      "LOCATION",
      "CHAT",
      "POINT",
      "SOS",
    ]);
    assert.equal(history[0].payload.latitude, 32);
    assert.equal(history[2].payload.name, "Updated name");
    assert.equal(history[3].payload.status, "CANCELLED");
    assert.equal(restored.getTeamHistory("team-b").length, 1);

    now += DEFAULT_HISTORY_RETENTION_MS + 1;
    const afterExpiry = new MessageStore(
      directory,
      DEFAULT_HISTORY_RETENTION_MS,
      () => now,
    );
    assert.deepEqual(afterExpiry.getTeamHistory("team-a"), []);
    assert.equal(
      JSON.parse(fs.readFileSync(path.join(directory, "messages.json"), "utf8"))
        .entries.length,
      0,
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
