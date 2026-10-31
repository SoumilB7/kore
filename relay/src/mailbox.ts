// One mailbox: one Mac's socket and up to two phones', forwarding opaque frames between them.
// It keeps nothing: no storage, only each socket's attachment (its role, slot and token hash,
// and on the host's the hashes it allowed), so it can sleep between frames (hibernation).
import { DurableObject } from "cloudflare:workers";
import { TokenBucket } from "./rate";
import {
  ALLOW, CLOSE, DATA, HOST_GRACE_MS, MAX_ALLOWED, MAX_PAYLOAD, MAX_PHONES, OPEN, REVOKE,
  frame, fromBase64URL, hex, mailboxOf, sha256,
} from "./frame";

type HostTag = { role: "host"; mailbox: string; token: string; allowed: string[] };
type PhoneTag = { role: "phone"; slot: number; token: string; hostGoneAt: number | null };
type Tag = HostTag | PhoneTag;

const NORMAL = 1000;
const PUT_OUT = 4000;

export class Mailbox extends DurableObject {
  /** Each socket's frame allowance (in memory only; a wake starts it full). */
  private rates = new WeakMap<WebSocket, TokenBucket>();

  async fetch(request: Request): Promise<Response> {
    const mailbox = new URL(request.url).pathname.slice(3);
    const role = request.headers.get("X-Kore-Role");
    const bearer = request.headers.get("Authorization")?.match(/^Bearer (.+)$/)?.[1];
    const token = bearer ? fromBase64URL(bearer) : null;
    if (!token || token.length !== 32 || (role !== "host" && role !== "phone")) return refuse(401);
    const tokenHash = hex(await sha256(token));
    return role === "host" ? this.joinHost(mailbox, token, tokenHash) : this.joinPhone(tokenHash);
  }

  private async joinHost(mailbox: string, token: Uint8Array, tokenHash: string): Promise<Response> {
    // Only the token that makes this mailbox's id can be its host.
    if ((await mailboxOf(token)) !== mailbox) return refuse(401);
    const old = this.host();
    const oldTag = old ? tag<HostTag>(old) : null;
    if (oldTag && oldTag.token !== tokenHash) return refuse(409);
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["host"]);
    server.serializeAttachment({ role: "host", mailbox, token: tokenHash, allowed: oldTag?.allowed ?? [] } satisfies HostTag);
    if (old) old.close(PUT_OUT, "replaced");
    for (const phone of this.phones()) {
      const t = tag<PhoneTag>(phone);
      server.send(frame(OPEN, t.slot));
      if (!old) {
        phone.serializeAttachment({ ...t, hostGoneAt: null });
        phone.send(frame(OPEN));
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  private joinPhone(tokenHash: string): Response {
    const host = this.host();
    if (!host) {
      this.expire();
      return refuse(404);
    }
    if (!tag<HostTag>(host).allowed.includes(tokenHash)) return refuse(401);
    const taken = new Set(this.phones().map((p) => tag<PhoneTag>(p).slot));
    const slot = [...Array(MAX_PHONES).keys()].find((s) => !taken.has(s));
    if (slot === undefined) return refuse(429);
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["phone"]);
    server.serializeAttachment({ role: "phone", slot, token: tokenHash, hostGoneAt: null } satisfies PhoneTag);
    host.send(frame(OPEN, slot));
    server.send(frame(OPEN));
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    const t = tag<Tag>(ws);
    if (typeof message === "string" || !this.withinRate(ws)) return ws.close(PUT_OUT, "refused");
    const bytes = new Uint8Array(message);
    if (t.role === "host") this.fromHost(ws, t, bytes);
    else this.fromPhone(ws, t, bytes);
  }

  private fromHost(ws: WebSocket, t: HostTag, bytes: Uint8Array): void {
    const kind = bytes[0];
    if (kind === DATA && bytes.length >= 2 && bytes.length <= MAX_PAYLOAD + 2 && bytes[1] < MAX_PHONES) {
      this.phone(bytes[1])?.send(frame(DATA, bytes.subarray(2)));
    } else if (kind === CLOSE && bytes.length === 2) {
      this.phone(bytes[1])?.close(PUT_OUT, "put out");
    } else if (kind === ALLOW && bytes.length === 33) {
      const hash = hex(bytes.subarray(1));
      if (!t.allowed.includes(hash)) {
        if (t.allowed.length >= MAX_ALLOWED) return ws.close(PUT_OUT, "refused");
        ws.serializeAttachment({ ...t, allowed: [...t.allowed, hash] });
      }
    } else if (kind === REVOKE && bytes.length === 33) {
      const hash = hex(bytes.subarray(1));
      ws.serializeAttachment({ ...t, allowed: t.allowed.filter((h) => h !== hash) });
      for (const phone of this.phones()) {
        const p = tag<PhoneTag>(phone);
        if (p.token !== hash) continue;
        phone.close(PUT_OUT, "revoked");
        ws.send(frame(CLOSE, p.slot));
      }
    } else {
      ws.close(PUT_OUT, "refused");
    }
  }

  private fromPhone(ws: WebSocket, t: PhoneTag, bytes: Uint8Array): void {
    const host = this.host();
    if (!host) {
      // The Mac is away; past the grace, its mailbox goes.
      if (t.hostGoneAt !== null && Date.now() - t.hostGoneAt > HOST_GRACE_MS) ws.close(PUT_OUT, "gone");
      return;
    }
    if (bytes[0] !== DATA || bytes.length > MAX_PAYLOAD + 1) return ws.close(PUT_OUT, "refused");
    host.send(frame(DATA, t.slot, bytes.subarray(1)));
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    this.gone(ws, code);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws, 1006);
  }

  private gone(ws: WebSocket, code: number): void {
    const t = tag<Tag>(ws);
    if (t.role === "phone") {
      this.host()?.send(frame(CLOSE, t.slot));
      return;
    }
    if (this.host() && this.host() !== ws) return; // replaced by a new host socket
    if (code === NORMAL) {
      // The Mac said goodbye: the mailbox is torn down.
      for (const phone of this.phones()) phone.close(NORMAL, "closed");
      return;
    }
    const at = Date.now();
    for (const phone of this.phones()) {
      phone.serializeAttachment({ ...tag<PhoneTag>(phone), hostGoneAt: at });
      phone.send(frame(CLOSE));
    }
  }

  /** Phones whose host has been gone past the grace are put out. */
  private expire(): void {
    for (const phone of this.phones()) {
      const t = tag<PhoneTag>(phone);
      if (t.hostGoneAt !== null && Date.now() - t.hostGoneAt > HOST_GRACE_MS) phone.close(PUT_OUT, "gone");
    }
  }

  private withinRate(ws: WebSocket): boolean {
    const now = Date.now();
    let bucket = this.rates.get(ws);
    if (!bucket) {
      bucket = new TokenBucket(now);
      this.rates.set(ws, bucket);
    }
    return bucket.take(now);
  }

  private host(): WebSocket | undefined {
    return this.ctx.getWebSockets("host").find((ws) => ws.readyState === WebSocket.OPEN);
  }

  private phones(): WebSocket[] {
    return this.ctx.getWebSockets("phone").filter((ws) => ws.readyState === WebSocket.OPEN);
  }

  private phone(slot: number): WebSocket | undefined {
    return this.phones().find((ws) => tag<PhoneTag>(ws).slot === slot);
  }
}

function tag<T extends Tag>(ws: WebSocket): T {
  return ws.deserializeAttachment() as T;
}

function refuse(status: number): Response {
  return new Response(null, { status });
}
