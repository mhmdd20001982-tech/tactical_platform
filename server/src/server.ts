import dotenv from "dotenv";
import http from "node:http";
import path from "node:path";
import express from "express";
import { WebSocketServer } from "ws";
import { MessageStore } from "./message-store";
import { SocketManager } from "./socket-manager";

dotenv.config({ path: path.join(__dirname, "../.env") });

const host = process.env.HOST ?? "0.0.0.0";
const port = Number(process.env.PORT ?? 8080);
const heartbeatMs = Number(process.env.HEARTBEAT_MS ?? 30_000);
const authToken = process.env.AUTH_TOKEN?.trim();
const serverDirectory = path.resolve(__dirname, "..");
const dataDirectory = path.resolve(
  serverDirectory,
  process.env.DATA_DIR ?? "data",
);
const app = express();
const httpServer = http.createServer(app);
const webSocketServer = new WebSocketServer({ server: httpServer, maxPayload: 1024 * 1024 });
const messageStore = new MessageStore(dataDirectory);
const socketManager = new SocketManager(webSocketServer, heartbeatMs, messageStore, authToken);
const historyCleanupTimer = setInterval(() => {
  try {
    const removed = messageStore.pruneExpired();
    if (removed > 0) console.log(`Expired ${removed} stored team messages`);
  } catch (error) {
    console.error("Failed to remove expired team messages", error);
  }
}, 60_000);
historyCleanupTimer.unref();

if (!authToken) {
  console.warn("AUTH_TOKEN is not set; WebSocket clients are unauthenticated");
}

app.get("/health", (_request, response) => {
  response.json({
    status: messageStore.healthy ? "ok" : "degraded",
    uptime: process.uptime(),
    connectedDevices: socketManager.connectedDeviceCount,
    storageHealthy: messageStore.healthy,
  });
});

app.get("/ready", (_request, response) => {
  const ready = messageStore.healthy;
  response.status(ready ? 200 : 503).json({
    status: ready ? "ready" : "not_ready",
    storageHealthy: messageStore.healthy,
  });
});

httpServer.listen(port, host, () => {
  console.log(`Tactical platform listening on http://${host}:${port}`);
});

function shutdown(): void {
  clearInterval(historyCleanupTimer);
  socketManager.shutdown();
  webSocketServer.close();
  httpServer.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
