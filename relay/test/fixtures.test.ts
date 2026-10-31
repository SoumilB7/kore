// The relay against the conformance fixtures the Mac's in-process relay is checked against too
// (`protocol/fixtures/relay`).
import { describe, expect, it } from "vitest";
import { hex, mailboxOf, sha256 } from "../src/frame";
import { Client, fromHex, join } from "./socket";

type Step = { op: string; as?: string; role?: string; token?: string; mailbox?: string; expect?: "ok" | number; frame?: string; pad?: number };
type Fixture = { name: string; hostToken: string; tokens: Record<string, string>; steps: Step[] };

const fixtures = import.meta.glob<Fixture>("../../protocol/fixtures/relay/*.json", { eager: true, import: "default" });

describe("relay fixtures", () => {
  for (const [path, f] of Object.entries(fixtures)) {
    it(path.split("/").pop()!, async () => {
      // A fresh host token per run: each fixture gets a mailbox of its own.
      const hostToken = crypto.getRandomValues(new Uint8Array(32));
      const mailbox = await mailboxOf(hostToken);
      const token = (name?: string) => (name === "host" ? hostToken : fromHex(f.tokens[name ?? ""]));
      const frame = async (text: string, pad = 0) => {
        let h = text;
        for (const [name, value] of Object.entries(f.tokens)) h = h.replaceAll(`{hash:${name}}`, hex(await sha256(fromHex(value))));
        const bytes = fromHex(h);
        const out = new Uint8Array(bytes.length + pad);
        out.set(bytes);
        return out;
      };
      const sockets: Record<string, Client> = {};
      for (const step of f.steps) {
        const who = step.as ?? "";
        switch (step.op) {
          case "connect": {
            const box = step.mailbox === "random" ? hex(crypto.getRandomValues(new Uint8Array(16))) : mailbox;
            const { client, status } = await join(box, step.role!, token(step.token));
            expect(client ? "ok" : status, `${f.name}: ${who}`).toEqual(step.expect);
            if (client) sockets[who] = client;
            break;
          }
          case "send":
            sockets[who].ws.send(await frame(step.frame!, step.pad));
            await new Promise((r) => setTimeout(r, 20));
            break;
          case "recv": {
            const got = await sockets[who].next();
            expect(got && hex(got), `${f.name}: ${who} got`).toEqual(hex(await frame(step.frame!)));
            break;
          }
          case "closed":
            expect(await sockets[who].closedWithin(), `${f.name}: ${who} closed`).toBe(true);
            break;
          case "close":
            sockets[who].ws.close(1000, "bye");
            await new Promise((r) => setTimeout(r, 20));
            break;
          case "drop":
            sockets[who].ws.close(4001, "dropped");
            await new Promise((r) => setTimeout(r, 20));
            break;
          default:
            throw new Error(`unknown op ${step.op}`);
        }
      }
    });
  }
});
