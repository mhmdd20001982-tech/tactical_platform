import { MAX_FRAME_BYTES, ProtocolError, ProtocolMessage, parseMessage } from "./messages";

export class FrameDecoder {
  private pending = "";

  constructor(private readonly maxFrameBytes = MAX_FRAME_BYTES) {}

  add(chunk: string): ProtocolMessage[] {
    this.pending += chunk;
    const messages: ProtocolMessage[] = [];
    let newline = this.pending.indexOf("\n");

    while (newline !== -1) {
      const line = this.pending.slice(0, newline).trim();
      this.pending = this.pending.slice(newline + 1);
      if (Buffer.byteLength(line, "utf8") > this.maxFrameBytes) {
        throw new ProtocolError("Frame too large", "frame_too_large");
      }
      if (line.length > 0) {
        messages.push(parseMessage(JSON.parse(line)));
      }
      newline = this.pending.indexOf("\n");
    }

    if (Buffer.byteLength(this.pending, "utf8") > this.maxFrameBytes) {
      throw new ProtocolError("Frame too large", "frame_too_large");
    }
    return messages;
  }
}
