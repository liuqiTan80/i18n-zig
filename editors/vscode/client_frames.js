// Minimal LSP base-protocol framing for the zzc VS Code client, zero npm
// dependencies (round 157). Deliberately vscode-free so the demos guard can
// require() this file directly under plain node and byte-test it; the
// extension host loads the same bytes through extension.js.
//
// Wire format is the LSP base protocol: "Content-Length: N\r\n\r\n" + body,
// N counted in BYTES (not characters). This mirrors src/lsp/jsonrpc.zig on the
// server side; the two ends are kept in sync by the shared handshake guard.
'use strict';

const MAX_FRAME_BYTES = 10 * 1024 * 1024; // same cap as the server (jsonrpc.zig)

// Encode one JSON-RPC message body into a full base-protocol frame buffer.
function encodeFrame(body) {
  const payload = Buffer.from(body, 'utf8');
  const header = Buffer.from('Content-Length: ' + payload.length + '\r\n\r\n', 'ascii');
  return Buffer.concat([header, payload]);
}

// Incremental parser: append() feeds raw chunks, take() drains complete frames.
// Handles split headers, split bodies, and several frames glued in one chunk.
class FrameDecoder {
  constructor() {
    this.buf = Buffer.alloc(0);
  }
  append(chunk) {
    this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk]);
  }
  // Returns { body, json } for the next complete frame, or null when more
  // bytes are still needed. Throws on malformed or oversized frames.
  take() {
    const sep = this.buf.indexOf('\r\n\r\n');
    if (sep < 0) return null;
    const headerText = this.buf.subarray(0, sep).toString('latin1');
    let contentLength = -1;
    for (const line of headerText.split('\r\n')) {
      const colon = line.indexOf(':');
      if (colon < 0) continue;
      const name = line.slice(0, colon).trim().toLowerCase();
      if (name === 'content-length') {
        contentLength = parseInt(line.slice(colon + 1).trim(), 10);
      }
    }
    if (!Number.isInteger(contentLength) || contentLength < 0) {
      throw new Error('帧格式非法：缺少或畸形的 Content-Length');
    }
    if (contentLength > MAX_FRAME_BYTES) {
      throw new Error('帧格式非法：Content-Length ' + contentLength + ' 超出上限');
    }
    const start = sep + 4;
    if (this.buf.length < start + contentLength) return null;
    const body = this.buf.subarray(start, start + contentLength).toString('utf8');
    this.buf = this.buf.subarray(start + contentLength);
    let json = null;
    try {
      json = JSON.parse(body);
    } catch (e) {
      throw new Error('帧格式非法：消息体不是合法 JSON：' + e.message);
    }
    return { body, json };
  }
}

// Test/reply helper used by the guard: encode then re-parse a round trip.
function roundTrip(body) {
  const d = new FrameDecoder();
  d.append(encodeFrame(body));
  const f = d.take();
  if (f === null) throw new Error('往返失败：帧未能解析回来');
  return f;
}

module.exports = { encodeFrame, FrameDecoder, roundTrip, MAX_FRAME_BYTES };
