import dotenv from "dotenv";
import http from "node:http";
import path from "node:path";
import express from "express";
import { WebSocketServer } from "ws";
import { SocketManager } from "./socket-manager";

dotenv.config({ path: path.join(__dirname, "../.env") });

const host = process.env.HOST ?? "0.0.0.0";
const port = Number(process.env.PORT ?? 8080);
const heartbeatMs = Number(process.env.HEARTBEAT_MS ?? 30_000);
const authToken = process.env.AUTH_TOKEN?.trim();
const app = express();
const httpServer = http.createServer(app);
const webSocketServer = new WebSocketServer({ server: httpServer, maxPayload: 1024 * 1024 });
const socketManager = new SocketManager(webSocketServer, heartbeatMs, authToken);

if (!authToken) {
  console.warn("AUTH_TOKEN is not set; WebSocket clients are unauthenticated");
}

app.get("/health", (_request, response) => {
  response.json({
    status: "ok",
    uptime: process.uptime(),
    connectedDevices: socketManager.connectedDeviceCount,
  });
});

app.get("/ready", (_request, response) => {
  response.json({ status: "ready" });
});

httpServer.listen(port, host, () => {
  console.log(`Tactical platform listening on http://${host}:${port}`);
});

function shutdown(): void {
  socketManager.shutdown();
  webSocketServer.close();
  httpServer.close(() => process.exit(0));
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
