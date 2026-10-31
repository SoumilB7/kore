// The relay's own limits beyond the shared fixtures: it stores nothing, it ends sockets that send
// too fast or the wrong kind of message, and it logs nothing about what passes.
import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import { FRAMES_PER_SECOND, frame, hex, mailboxOf, sha256 } from "../src/frame";
import { TokenBucket } from "../src/rate";
import { join } from "./socket";

async function hostWithPhone() {
  const hostToken = crypto.getRandomValues(new Uint8Array(32));
  const phoneToken = crypto.getRandomValues(new Uint8Array(32));
  const mailbox = await mailboxOf(hostToken);
  const host = (await join(mailbox, "host", hostToken)).client!;
  host.ws.send(frame(0x10, await sha256(phoneToken)));
  await new Promise((r) => setTimeout(r, 20));
  const phone = (await join(mailbox, "phone", phoneToken)).client!;
  await phone.next();
  await host.next();
  return { mailbox, host, phone };
}

describe("relay", () => {
  it("stores nothing", async () => {
    const { mailbox, host, phone } = await hostWithPhone();
    phone.ws.send(frame(0x01, new Uint8Array([1, 2, 3])));
    await host.next();
    const stub = env.MAILBOX.get(env.MAILBOX.idFromName(mailbox));
    await runInDurableObject(stub, async (_, state) => {
      expect((await state.storage.list()).size).toBe(0);
    });
  });

  it("ends a socket that sends too fast", async () => {
    const { phone } = await hostWithPhone();
    // Three seconds' worth at once: past the bucket whatever the clock does meanwhile.
    for (let i = 0; i < FRAMES_PER_SECOND * 3; i++) phone.ws.send(frame(0x01, new Uint8Array([i & 0xff])));
    expect(await phone.closedWithin(5000)).toBe(true);
  });

  it("allows a second's worth at once, then refills by the millisecond", () => {
    const bucket = new TokenBucket(0);
    for (let i = 0; i < FRAMES_PER_SECOND; i++) expect(bucket.take(0)).toBe(true);
    expect(bucket.take(0)).toBe(false);
    // 1000 / FRAMES_PER_SECOND ms gives one frame back; a boundary gives nothing extra.
    expect(bucket.take(1000 / FRAMES_PER_SECOND)).toBe(true);
    expect(bucket.take(1000 / FRAMES_PER_SECOND)).toBe(false);
    // Half a second on, half a bucket: never a second bucket on top of the first, as a fixed
    // window's boundary would give.
    let taken = 0;
    while (bucket.take(500 + 1000 / FRAMES_PER_SECOND)) taken++;
    expect(Math.abs(taken - FRAMES_PER_SECOND / 2)).toBeLessThanOrEqual(1);
  });

  it("ends a socket that sends text", async () => {
    const { phone } = await hostWithPhone();
    phone.ws.send("hello");
    expect(await phone.closedWithin()).toBe(true);
  });

  it("refuses requests that aren't a mailbox's WebSocket", async () => {
    const { exports } = await import("cloudflare:workers");
    expect((await exports.default.fetch("https://relay.test/")).status).toBe(404);
    expect((await exports.default.fetch(`https://relay.test/m/${hex(new Uint8Array(16))}`)).status).toBe(426);
    const bad = await exports.default.fetch(`https://relay.test/m/${hex(new Uint8Array(16))}`, {
      headers: { Upgrade: "websocket", "X-Kore-Role": "phone", Authorization: "Bearer !!" },
    });
    expect(bad.status).toBe(401);
  });

  it("logs nothing about frames", async () => {
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((k) => vi.spyOn(console, k));
    const { host, phone } = await hostWithPhone();
    phone.ws.send(frame(0x01, new Uint8Array([9, 9, 9])));
    await host.next();
    for (const spy of spies) expect(spy).not.toHaveBeenCalled();
  });
});
