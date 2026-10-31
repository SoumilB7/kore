// A test's client for the relay: joins a mailbox over the Worker's fetch, and reads frames with
// a deadline.
import { exports } from "cloudflare:workers";

export type Joined = { ws: WebSocket; status: 101 } | { ws: null; status: number };

export function base64URL(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export class Client {
  private queue: Uint8Array[] = [];
  private waiting: ((b: Uint8Array | null) => void) | null = null;
  closed = false;

  constructor(readonly ws: WebSocket) {
    ws.accept();
    // A test's end of the socket gets Blobs: read in order.
    let order = Promise.resolve();
    ws.addEventListener("message", (e) => {
      const data = e.data as ArrayBuffer | Blob;
      order = order.then(async () => this.push(new Uint8Array(data instanceof Blob ? await data.arrayBuffer() : data)));
    });
    ws.addEventListener("close", () => {
      this.closed = true;
      this.waiting?.(null);
      this.waiting = null;
    });
  }

  private push(bytes: Uint8Array) {
    if (this.waiting) {
      this.waiting(bytes);
      this.waiting = null;
    } else this.queue.push(bytes);
  }

  /** The next frame, or null once closed or after `ms`. */
  next(ms = 2000): Promise<Uint8Array | null> {
    const queued = this.queue.shift();
    if (queued) return Promise.resolve(queued);
    if (this.closed) return Promise.resolve(null);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiting = null;
        resolve(null);
      }, ms);
      this.waiting = (b) => {
        clearTimeout(timer);
        resolve(b);
      };
    });
  }

  /** Waits until the relay closes it. */
  async closedWithin(ms = 2000): Promise<boolean> {
    const end = Date.now() + ms;
    while (!this.closed && Date.now() < end) await new Promise((r) => setTimeout(r, 10));
    return this.closed;
  }
}

export async function join(mailbox: string, role: string, token: Uint8Array): Promise<{ client: Client | null; status: number }> {
  const response = await exports.default.fetch(`https://relay.test/m/${mailbox}`, {
    headers: { Upgrade: "websocket", "X-Kore-Role": role, Authorization: `Bearer ${base64URL(token)}` },
  });
  return response.webSocket ? { client: new Client(response.webSocket), status: 101 } : { client: null, status: response.status };
}

export function fromHex(hex: string): Uint8Array {
  return Uint8Array.from(hex.match(/../g) ?? [], (b) => parseInt(b, 16));
}
