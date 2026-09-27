import assert from "node:assert/strict";
import { once } from "node:events";
import http from "node:http";
import { after, before, test } from "node:test";
import { WebSocket, WebSocketServer } from "ws";
import { SocketManager } from "../src/socket-manager";

const httpServer = http.createServer();
const webSocketServer = new WebSocketServer({ server: httpServer });
const manager = new SocketManager(webSocketServer, 60_000, "test-secret");
let address: string;

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
