import {
  isRecord,
  parseMessage,
  ProtocolMessage,
} from "@tactical-platform/protocol";
import fs from "node:fs";
import path from "node:path";

const STORE_VERSION = 1;
export const DEFAULT_HISTORY_RETENTION_MS = 24 * 60 * 60 * 1000;

interface StoredMessage {
  teamId: string;
  storedAt: number;
  message: ProtocolMessage;
}

interface PersistedStore {
  version: number;
  entries: StoredMessage[];
}

function isStoredType(type: string): boolean {
  return type === "LOCATION" || type === "CHAT" || type === "POINT" || type === "SOS";
}

function storageKey(message: ProtocolMessage): string {
  let entityId: string;
  switch (message.type) {
    case "LOCATION":
      entityId = message.sender_id;
      break;
    case "CHAT":
      entityId = message.id;
      break;
    case "POINT":
      entityId = String(message.payload.point_id);
      break;
    case "SOS":
      entityId = String(message.payload.event_id);
      break;
    default:
      throw new Error(`Unsupported stored message type: ${message.type}`);
  }
  return JSON.stringify([message.team_id, message.type, entityId]);
}

export class MessageStore {
  private readonly filePath: string;
  private readonly entries = new Map<string, StoredMessage>();
  private lastFailure?: string;

  constructor(
    dataDirectory: string,
    private readonly retentionMs = DEFAULT_HISTORY_RETENTION_MS,
    private readonly now: () => number = Date.now,
  ) {
    if (!Number.isFinite(retentionMs) || retentionMs <= 0) {
      throw new RangeError("History retention must be a positive duration");
    }
    fs.mkdirSync(dataDirectory, { recursive: true, mode: 0o700 });
    this.filePath = path.join(dataDirectory, "messages.json");
    this.load();
    this.pruneExpired();
  }

  get healthy(): boolean {
    return this.lastFailure === undefined;
  }

  record(message: ProtocolMessage): void {
    if (!isStoredType(message.type)) return;
    if (!message.team_id) {
      throw new Error("Cannot persist a team message without team_id");
    }

    const key = storageKey(message);
    const previous = this.entries.get(key);
    this.entries.set(key, {
      teamId: message.team_id,
      storedAt: this.now(),
      message,
    });
    try {
      this.persist();
    } catch (error) {
      if (previous) this.entries.set(key, previous);
      else this.entries.delete(key);
      throw error;
    }
  }

  getTeamHistory(teamId: string): ProtocolMessage[] {
    const cutoff = this.now() - this.retentionMs;
    return [...this.entries.values()]
      .filter((entry) => entry.teamId === teamId && entry.storedAt >= cutoff)
      .sort((left, right) => left.storedAt - right.storedAt)
      .map((entry) => entry.message);
  }

  pruneExpired(): number {
    const cutoff = this.now() - this.retentionMs;
    let removed = 0;
    for (const [key, entry] of this.entries) {
      if (entry.storedAt < cutoff) {
        this.entries.delete(key);
        removed++;
      }
    }
    if (removed > 0) this.persist();
    return removed;
  }

  private load(): void {
    if (!fs.existsSync(this.filePath)) return;

    const raw: unknown = JSON.parse(fs.readFileSync(this.filePath, "utf8"));
    if (!isRecord(raw) || raw.version !== STORE_VERSION || !Array.isArray(raw.entries)) {
      throw new Error(`Invalid message store format: ${this.filePath}`);
    }
    for (const value of raw.entries) {
      if (!isRecord(value) || typeof value.teamId !== "string" ||
          typeof value.storedAt !== "number" || !Number.isFinite(value.storedAt)) {
        throw new Error(`Invalid message store entry: ${this.filePath}`);
      }
      const message = parseMessage(value.message);
      if (!isStoredType(message.type) || message.team_id !== value.teamId) {
        throw new Error(`Invalid persisted team message: ${this.filePath}`);
      }
      this.entries.set(storageKey(message), {
        teamId: value.teamId,
        storedAt: value.storedAt,
        message,
      });
    }
  }

  private persist(): void {
    const temporaryPath = `${this.filePath}.tmp`;
    const persisted: PersistedStore = {
      version: STORE_VERSION,
      entries: [...this.entries.values()],
    };
    try {
      fs.writeFileSync(temporaryPath, JSON.stringify(persisted), {
        encoding: "utf8",
        mode: 0o600,
      });
      fs.renameSync(temporaryPath, this.filePath);
      this.lastFailure = undefined;
    } catch (error) {
      this.lastFailure = error instanceof Error ? error.message : String(error);
      throw error;
    }
  }
}
