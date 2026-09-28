import assert from "node:assert/strict";
import { once } from "node:events";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import { createMessage } from "@tactical-platform/protocol";
import { MessageStore } from "../src/message-store";
import { SocketManager } from "../src/socket-manager";

const httpServer = http.createServer();
const webSocketServer = new WebSocketServer({ server: httpServer });
const dataDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "tactical-ws-"));
const manager = new SocketManager(
  webSocketServer,
  60_000,
  new MessageStore(dataDirectory),
  "test-secret",
);
let address: string;

function createMessageReader(socket: WebSocket): () => Promise<Buffer> {
  const queued: Buffer[] = [];
  const pending: Array<(message: Buffer) => void> = [];
  socket.on("message", (data) => {
    const message = Buffer.from(data.toString());
    const resolve = pending.shift();
    if (resolve) resolve(message);
    else queued.push(message);
  });
  return () => new Promise((resolve) => {
    const message = queued.shift();
    if (message) resolve(message);
    else pending.push(resolve);
  });
}

async function connectClient(
  deviceId: string,
  teamId: string,
): Promise<{ socket: WebSocket; readMessage: () => Promise<Buffer> }> {
  const socket = new WebSocket(address);
  await once(socket, "open");
  const readMessage = createMessageReader(socket);
  const acknowledgement = readMessage();
  socket.send(JSON.stringify({
    v: 1,
    type: "HELLO",
    id: `hello-${deviceId}`,
    sender_id: deviceId,
    ts: Date.now(),
    team_id: teamId,
    payload: { device_id: deviceId, name: deviceId, token: "test-secret" },
  }));
  const ack = JSON.parse((await acknowledgement).toString()) as {
    type: string;
    payload: { acked_message_id: string };
  };
  assert.equal(ack.type, "ACK");
  assert.equal(ack.payload.acked_message_id, `hello-${deviceId}`);
  return { socket, readMessage };
}

async function closeClient(socket: WebSocket): Promise<void> {
  if (socket.readyState !== WebSocket.OPEN) return;
  const closed = once(socket, "close");
  socket.close();
  await closed;
}

async function assertNoMessageDuring(socket: WebSocket, durationMs: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const onMessage = (data: Buffer) => {
      clearTimeout(timer);
      reject(new Error(`Unexpected cross-team message: ${data.toString()}`));
    };
    const timer = setTimeout(() => {
      socket.off("message", onMessage);
      resolve();
    }, durationMs);
    socket.once("message", onMessage);
  });
}

before(async () => {
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));
  const serverAddress = httpServer.address();
  assert(serverAddress && typeof serverAddress !== "string");
  address = `ws://127.0.0.1:${serverAddress.port}`;
});

after(async () => {
  manager.shutdown();
  await new Promise<void>((resolve) => webSocketServer.close(() => resolve()));
  await new Promise<void>((resolve) => httpServer.close(() => resolve()));
  fs.rmSync(dataDirectory, { recursive: true, force: true });
});

test("requires a matching token before accepting HELLO", async () => {
  const rejectedSocket = new WebSocket(address);
  await once(rejectedSocket, "open");
  const rejectedMessage = once(rejectedSocket, "message");
  rejectedSocket.send(JSON.stringify({
    v: 1,
    type: "HELLO",
    id: "hello-invalid",
    sender_id: "device-invalid",
    ts: Date.now(),
    team_id: "team-test",
    payload: { device_id: "device-invalid", name: "Invalid client", token: "wrong" },
  }));
  const [rawRejected] = await rejectedMessage;
  const rejection = JSON.parse(rawRejected.toString()) as { type: string; payload: { code: string } };
  assert.equal(rejection.type, "ERROR");
  assert.equal(rejection.payload.code, "unauthorized");
  assert.equal(manager.connectedDeviceCount, 0);
  rejectedSocket.close();
  await once(rejectedSocket, "close");

  const acceptedSocket = new WebSocket(address);
  await once(acceptedSocket, "open");
  const acceptedMessage = once(acceptedSocket, "message");
  acceptedSocket.send(JSON.stringify({
    v: 1,
    type: "HELLO",
    id: "hello-valid",
    sender_id: "device-valid",
    ts: Date.now(),
    team_id: "team-test",
    payload: { device_id: "device-valid", name: "Valid client", token: "test-secret" },
  }));
  const [rawAccepted] = await acceptedMessage;
  const acknowledgement = JSON.parse(rawAccepted.toString()) as {
    type: string;
    payload: { acked_message_id: string };
  };
  assert.equal(acknowledgement.type, "ACK");
  assert.equal(acknowledgement.payload.acked_message_id, "hello-valid");
  assert.equal(manager.connectedDeviceCount, 1);
  acceptedSocket.close();
  await once(acceptedSocket, "close");
});

test("restores retained team messages after an authenticated HELLO", async () => {
  const originalSocket = new WebSocket(address);
  await once(originalSocket, "open");
  const originalAck = once(originalSocket, "message");
  originalSocket.send(JSON.stringify({
    v: 1,
    type: "HELLO",
    id: "hello-original",
    sender_id: "device-original",
    ts: Date.now(),
    team_id: "team-history",
    payload: { device_id: "device-original", name: "Original", token: "test-secret" },
  }));
  await originalAck;

  const readOriginalMessage = createMessageReader(originalSocket);
  const locationBroadcast = readOriginalMessage();
  const locationAcknowledgement = readOriginalMessage();
  originalSocket.send(JSON.stringify({
    v: 1,
    type: "LOCATION",
    id: "location-retained",
    sender_id: "device-original",
    ts: Date.now(),
    team_id: "team-history",
    payload: {
      latitude: 31.9,
      longitude: 35.8,
      recorded_at: Date.now(),
      device_name: "Original",
    },
  }));
  const echoedLocation = JSON.parse((await locationBroadcast).toString()) as {
    type: string;
    id: string;
  };
  const locationAck = JSON.parse((await locationAcknowledgement).toString()) as {
    type: string;
    payload: { acked_message_id: string };
  };
  assert.equal(echoedLocation.type, "LOCATION");
  assert.equal(echoedLocation.id, "location-retained");
  assert.equal(locationAck.type, "ACK");
  assert.equal(locationAck.payload.acked_message_id, "location-retained");

  const reconnectingSocket = new WebSocket(address);
  await once(reconnectingSocket, "open");
  const readMessage = createMessageReader(reconnectingSocket);
  const acknowledgement = readMessage();
  const restoredMessage = readMessage();
  reconnectingSocket.send(JSON.stringify({
    v: 1,
    type: "HELLO",
    id: "hello-reconnect",
    sender_id: "device-reconnect",
    ts: Date.now(),
    team_id: "team-history",
    payload: { device_id: "device-reconnect", name: "Reconnect", token: "test-secret" },
  }));
  assert.equal(JSON.parse((await acknowledgement).toString()).type, "ACK");

  const restored = JSON.parse((await restoredMessage).toString()) as {
    type: string;
    id: string;
    payload: { is_history?: boolean };
  };
  assert.equal(restored.type, "LOCATION");
  assert.equal(restored.id, "location-retained");
  assert.equal(restored.payload.is_history, true);

  const originalClosed = once(originalSocket, "close");
  const reconnectingClosed = once(reconnectingSocket, "close");
  originalSocket.close();
  reconnectingSocket.close();
  await Promise.all([originalClosed, reconnectingClosed]);
});

test("broadcasts live messages only within a team and restores history to a late device", async () => {
  const sender = await connectClient("multi-sender", "team-multi-device");
  const peer = await connectClient("multi-peer", "team-multi-device");
  const otherTeam = await connectClient("other-team-device", "team-isolated");
  const lateJoiner = { socket: undefined as WebSocket | undefined };

  try {
    const outgoing = createMessage(
      "CHAT",
      "multi-sender",
      { text: "Team-only update" },
      "team-multi-device",
    );
    const peerMessage = peer.readMessage();
    sender.socket.send(JSON.stringify(outgoing));

    const delivered = JSON.parse((await peerMessage).toString()) as {
      type: string;
      id: string;
      payload: { text: string; is_history?: boolean };
    };
    assert.equal(delivered.type, "CHAT");
    assert.equal(delivered.id, outgoing.id);
    assert.equal(delivered.payload.text, "Team-only update");
    assert.equal(delivered.payload.is_history, undefined);
    await assertNoMessageDuring(otherTeam.socket, 100);

    lateJoiner.socket = new WebSocket(address);
    await once(lateJoiner.socket, "open");
    const readLateMessage = createMessageReader(lateJoiner.socket);
    const ack = readLateMessage();
    const history = readLateMessage();
    lateJoiner.socket.send(JSON.stringify({
      v: 1,
      type: "HELLO",
      id: "hello-multi-late",
      sender_id: "multi-late",
      ts: Date.now(),
      team_id: "team-multi-device",
      payload: {
        device_id: "multi-late",
        name: "Late device",
        token: "test-secret",
      },
    }));
    assert.equal(JSON.parse((await ack).toString()).type, "ACK");
    const restored = JSON.parse((await history).toString()) as {
      type: string;
      id: string;
      payload: { is_history?: boolean; text?: string };
    };
    assert.equal(restored.type, "CHAT");
    assert.equal(restored.id, outgoing.id);
    assert.equal(restored.payload.text, "Team-only update");
    assert.equal(restored.payload.is_history, true);
  } finally {
    await closeClient(sender.socket);
    await closeClient(peer.socket);
    await closeClient(otherTeam.socket);
    if (lateJoiner.socket) await closeClient(lateJoiner.socket);
  }
});
