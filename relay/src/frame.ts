// The relay's framing, as `Sources/KoreRemote/Relay/RelayFrame.swift` has it: one binary
// WebSocket message per frame, its first byte the kind. The relay reads only this byte, a
// phone's slot, and a token's hash; a data frame's payload is the encrypted session's bytes.

export const DATA = 0x01;
export const OPEN = 0x02;
export const CLOSE = 0x03;
export const ALLOW = 0x10;
export const REVOKE = 0x11;

/** The most payload a data frame carries: 64 KiB. */
export const MAX_PAYLOAD = 65536;
/** Phones in one mailbox at once. */
export const MAX_PHONES = 2;
/** Frames one socket may send in a second. */
export const FRAMES_PER_SECOND = 400;
/** Tokens a host may have allowed at once. */
export const MAX_ALLOWED = 16;
/** How long phones stay once their host dropped without a goodbye. */
export const HOST_GRACE_MS = 10 * 60 * 1000;

export function frame(kind: number, ...parts: (number | Uint8Array)[]): Uint8Array {
  const size = 1 + parts.reduce((n, p) => n + (typeof p === "number" ? 1 : p.length), 0);
  const out = new Uint8Array(size);
  out[0] = kind;
  let i = 1;
  for (const p of parts) {
    if (typeof p === "number") out[i++] = p;
    else {
      out.set(p, i);
      i += p.length;
    }
  }
  return out;
}

export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

/** The mailbox a host token opens: SHA-256("kore mailbox" ‖ token), its first 16 bytes. */
export async function mailboxOf(hostToken: Uint8Array): Promise<string> {
  const label = new TextEncoder().encode("kore mailbox");
  const joined = new Uint8Array(label.length + hostToken.length);
  joined.set(label);
  joined.set(hostToken, label.length);
  return hex((await sha256(joined)).slice(0, 16));
}

export function fromBase64URL(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) return null;
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  try {
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}
