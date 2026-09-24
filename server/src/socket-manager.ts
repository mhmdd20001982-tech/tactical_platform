import { IncomingMessage } from "node:http";
import { RawData, WebSocket, WebSocketServer } from "ws";
import {
  createMessage,
  HelloPayload,
  parseMessage,
  ProtocolError,
  ProtocolMessage,
} from "@tactical-platform/protocol";

interface Client {
  socket: WebSocket;
  deviceId?: string;
  teamId?: string;
  alive: boolean;
}

export class SocketManager {
  private readonly clients = new Set<Client>();
  private readonly devices = new Map<string, number>();
  private heartbeatTimer: NodeJS.Timeout;

  constructor(
    private readonly server: WebSocketServer,
    private readonly heartbeatMs: number,
  ) {
    this.server.on("connection", (socket, request) => this.connect(socket, request));
    this.heartbeatTimer = setInterval(() => this.heartbeat(), heartbeatMs);
    this.heartbeatTimer.unref();
  }

  get connectedDeviceCount(): number {
    return this.devices.size;
  }

  shutdown(): void {
    clearInterval(this.heartbeatTimer);
    for (const client of this.clients) client.socket.terminate();
    this.clients.clear();
    this.devices.clear();
  }

  private connect(socket: WebSocket, _request: IncomingMessage): void {
    const client: Client = { socket, alive: true };
    this.clients.add(client);
    console.log(`WebSocket client connected (active sessions: ${this.clients.size})`);
    socket.on("pong", () => (client.alive = true));
    socket.on("message", (data) => this.message(client, data));
    socket.on("close", () => this.remove(client));
    socket.on("error", () => this.remove(client));
  }

  private message(client: Client, raw: RawData): void {
    let message: ProtocolMessage;
    try {
      message = parseMessage(JSON.parse(raw.toString()));
    } catch (error) {
      const protocolError = error instanceof ProtocolError ? error : new ProtocolError("Invalid JSON", "invalid_json");
      this.send(client, createMessage("ERROR", "server", {
        code: protocolError.code,
        message: protocolError.message,
      }));
      return;
    }

    if (message.type === "HELLO") {
      this.acceptHello(client, message);
      return;
    }
    if (!client.deviceId || !client.teamId) {
      this.send(client, createMessage("ERROR", "server", {
        code: "handshake_required",
        message: "HELLO must be accepted before sending data",
      }));
      return;
    }
    if (message.sender_id !== client.deviceId || message.team_id !== client.teamId) {
      this.send(client, createMessage("ERROR", "server", {
        code: "identity_mismatch",
        message: "Message identity does not match the active session",
      }, client.teamId));
      return;
    }
    if (message.type === "PING") {
      this.send(client, createMessage("PONG", "server", {}, client.teamId));
      return;
    }
    this.broadcast(message, client.teamId);
  }

  private acceptHello(client: Client, message: ProtocolMessage): void {
    const hello = message.payload as unknown as HelloPayload;
    const teamId = typeof message.team_id === "string" ? message.team_id : undefined;
    if (!teamId) {
      this.send(client, createMessage("ERROR", "server", {
        code: "missing_team_id",
        message: "HELLO requires team_id",
      }));
      return;
    }
    client.deviceId = hello.device_id;
    client.teamId = teamId;
    this.devices.set(hello.device_id, Date.now());
    console.log(
      `HELLO accepted: device=${hello.device_id} name=${hello.name} team=${teamId}`,
    );
    this.send(client, createMessage("ACK", "server", {
      acked_message_id: message.id,
    }, teamId));
  }

  private broadcast(message: ProtocolMessage, teamId: string): void {
    if (message.type === "LOCATION") {
      const payload = message.payload as {
        latitude?: number;
        longitude?: number;
        device_name?: string;
      };
      console.log(
        `LOCATION received: device=${message.sender_id} name=${payload.device_name ?? "unknown"} ` +
          `lat=${payload.latitude} lon=${payload.longitude} team=${teamId}`,
      );
    }
    for (const client of this.clients) {
      if (client.teamId === teamId && client.socket.readyState === WebSocket.OPEN) {
        client.socket.send(JSON.stringify(message));
      }
    }
  }

  private heartbeat(): void {
    for (const client of this.clients) {
      if (!client.alive) {
        client.socket.terminate();
        this.remove(client);
        continue;
      }
      client.alive = false;
      if (client.socket.readyState === WebSocket.OPEN) client.socket.ping();
    }
  }

  private send(client: Client, message: ProtocolMessage): void {
    if (client.socket.readyState === WebSocket.OPEN) {
      client.socket.send(JSON.stringify(message));
    }
  }

  private remove(client: Client): void {
    this.clients.delete(client);
    if (client.deviceId && !Array.from(this.clients).some((entry) => entry.deviceId === client.deviceId)) {
      this.devices.delete(client.deviceId);
    }
    console.log(
      `WebSocket client disconnected${client.deviceId ? `: device=${client.deviceId}` : ""} ` +
        `(active sessions: ${this.clients.size})`,
    );
  }
}
