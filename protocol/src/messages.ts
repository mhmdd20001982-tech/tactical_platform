export const PROTOCOL_VERSION = 1;
export const MAX_FRAME_BYTES = 1024 * 1024;

export type MessageType =
  | "HELLO"
  | "ACK"
  | "PING"
  | "PONG"
  | "LOCATION"
  | "CHAT"
  | "POINT"
  | "SOS"
  | "ERROR";

export interface ProtocolMessage<TPayload = Record<string, unknown>> {
  v: 1;
  type: MessageType;
  id: string;
  sender_id: string;
  ts: number;
  team_id?: string;
  payload: TPayload;
}

export interface HelloPayload {
  device_id: string;
  name: string;
  token?: string;
}

export interface LocationPayload {
  latitude: number;
  longitude: number;
  accuracy?: number;
  speed?: number;
  bearing?: number;
  recorded_at: number;
}

export interface ChatPayload {
  text: string;
  reply_to?: string;
}

export interface PointPayload {
  point_id: string;
  name: string;
  latitude: number;
  longitude: number;
  description?: string;
}

export interface SosPayload {
  event_id: string;
  status: "ACTIVE" | "CANCELLED";
  latitude: number;
  longitude: number;
  battery_level?: number;
}

export interface ErrorPayload {
  code: string;
  message: string;
}

const MESSAGE_TYPES = new Set<MessageType>([
  "HELLO",
  "ACK",
  "PING",
  "PONG",
  "LOCATION",
  "CHAT",
  "POINT",
  "SOS",
  "ERROR",
]);

export class ProtocolError extends Error {
  constructor(
    message: string,
    public readonly code = "invalid_message",
  ) {
    super(message);
    this.name = "ProtocolError";
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requiredString(
  value: unknown,
  field: string,
  maxLength = 256,
): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new ProtocolError(`Invalid ${field}`, "invalid_field");
  }
  const result = value.trim();
  if (result.length > maxLength) {
    throw new ProtocolError(`${field} is too long`, "field_too_long");
  }
  return result;
}

function requiredFiniteNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ProtocolError(`Invalid ${field}`, "invalid_field");
  }
  return value;
}

function parsePayload(type: MessageType, payload: unknown): Record<string, unknown> {
  if (!isRecord(payload)) {
    throw new ProtocolError("payload must be an object", "invalid_payload");
  }

  switch (type) {
    case "HELLO":
      return {
        device_id: requiredString(payload.device_id, "device_id", 128),
        name: requiredString(payload.name, "name", 128),
        ...(payload.token === undefined
          ? {}
          : { token: requiredString(payload.token, "token", 512) }),
      };
    case "LOCATION": {
      const latitude = requiredFiniteNumber(payload.latitude, "latitude");
      const longitude = requiredFiniteNumber(payload.longitude, "longitude");
      if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
        throw new ProtocolError("Location is outside valid bounds", "invalid_location");
      }
      return {
        latitude,
        longitude,
        recorded_at: requiredFiniteNumber(payload.recorded_at, "recorded_at"),
        ...(payload.device_name === undefined
          ? {}
          : { device_name: requiredString(payload.device_name, "device_name", 128) }),
        ...(payload.accuracy === undefined
          ? {}
          : { accuracy: requiredFiniteNumber(payload.accuracy, "accuracy") }),
        ...(payload.speed === undefined
          ? {}
          : { speed: requiredFiniteNumber(payload.speed, "speed") }),
        ...(payload.bearing === undefined
          ? {}
          : { bearing: requiredFiniteNumber(payload.bearing, "bearing") }),
      };
    }
    case "CHAT":
      return {
        text: requiredString(payload.text, "text", 4096),
        ...(payload.reply_to === undefined
          ? {}
          : { reply_to: requiredString(payload.reply_to, "reply_to", 128) }),
      };
    case "POINT": {
      const latitude = requiredFiniteNumber(payload.latitude, "latitude");
      const longitude = requiredFiniteNumber(payload.longitude, "longitude");
      if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
        throw new ProtocolError("Point is outside valid bounds", "invalid_location");
      }
      return {
        point_id: requiredString(payload.point_id, "point_id", 128),
        name: requiredString(payload.name, "name", 256),
        latitude,
        longitude,
        ...(payload.description === undefined
          ? {}
          : { description: requiredString(payload.description, "description", 4096) }),
      };
    }
    case "SOS": {
      const latitude = requiredFiniteNumber(payload.latitude, "latitude");
      const longitude = requiredFiniteNumber(payload.longitude, "longitude");
      if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
        throw new ProtocolError("SOS location is outside valid bounds", "invalid_location");
      }
      if (payload.status !== "ACTIVE" && payload.status !== "CANCELLED") {
        throw new ProtocolError("Invalid SOS status", "invalid_field");
      }
      return {
        event_id: requiredString(payload.event_id, "event_id", 128),
        status: payload.status,
        latitude,
        longitude,
        ...(payload.battery_level === undefined
          ? {}
          : { battery_level: requiredFiniteNumber(payload.battery_level, "battery_level") }),
      };
    }
    case "ACK":
      return { acked_message_id: requiredString(payload.acked_message_id, "acked_message_id", 128) };
    case "ERROR":
      return {
        code: requiredString(payload.code, "code", 128),
        message: requiredString(payload.message, "message", 1024),
      };
    case "PING":
    case "PONG":
      return {};
  }
}

export function parseMessage(raw: unknown): ProtocolMessage {
  if (!isRecord(raw)) {
    throw new ProtocolError("Message must be an object");
  }
  if (raw.v !== PROTOCOL_VERSION) {
    throw new ProtocolError("Unsupported protocol version", "unsupported_version");
  }
  if (typeof raw.type !== "string" || !MESSAGE_TYPES.has(raw.type as MessageType)) {
    throw new ProtocolError("Unknown message type", "unknown_type");
  }
  const type = raw.type as MessageType;
  const message: ProtocolMessage = {
    v: 1,
    type,
    id: requiredString(raw.id, "id", 128),
    sender_id: requiredString(raw.sender_id, "sender_id", 128),
    ts: requiredFiniteNumber(raw.ts, "ts"),
    ...(raw.team_id === undefined ? {} : { team_id: requiredString(raw.team_id, "team_id", 128) }),
    payload: parsePayload(type, raw.payload),
  };
  if (type !== "HELLO" && type !== "ACK" && type !== "PING" && !message.team_id) {
    throw new ProtocolError("team_id is required for this message", "missing_team_id");
  }
  return message;
}

export function encodeMessage(message: ProtocolMessage): string {
  return `${JSON.stringify(message)}\n`;
}

export function createMessage(
  type: MessageType,
  senderId: string,
  payload: Record<string, unknown>,
  teamId?: string,
): ProtocolMessage {
  return {
    v: 1,
    type,
    id: crypto.randomUUID(),
    sender_id: senderId,
    ts: Date.now(),
    ...(teamId ? { team_id: teamId } : {}),
    payload,
  };
}
