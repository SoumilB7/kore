import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { Message, MESSAGE_TYPES } from "../src/schema";

const dir = join(dirname(fileURLToPath(import.meta.url)), "../fixtures/v1");
const manifest: { fixtures: { file: string; t: string; future: boolean; kotlin: boolean }[] } = JSON.parse(
  readFileSync(join(dir, "manifest.json"), "utf8"),
);
const read = (file: string) => JSON.parse(readFileSync(join(dir, file), "utf8"));

describe("protocol v1 fixtures", () => {
  it("covers every message type", () => {
    const covered = new Set(manifest.fixtures.filter((f) => !f.future).map((f) => f.t));
    expect([...MESSAGE_TYPES].sort()).toEqual([...covered].sort());
  });

  for (const fixture of manifest.fixtures) {
    it(`${fixture.file} reads${fixture.future ? "" : " and writes back the same"}`, () => {
      const raw = read(fixture.file);
      const parsed = Message.parse(raw);
      expect(parsed.t).toBe(fixture.t);
      if (!fixture.future) expect(JSON.parse(JSON.stringify(parsed))).toEqual(raw);
    });
  }

  it("reads values from a newer host as unknown", () => {
    const parsed = Message.parse(read("future.unknown-values.json"));
    if (parsed.t !== "delta") throw new Error("not a delta");
    const chat = parsed.chats![0];
    expect(chat.state).toBe("unknown");
    expect(chat.cards[0].kind).toBe("unknown");
    expect(chat.cards[0].actions[0].id).toBe("unknown");
    expect(chat.cards[0].actions[0].style).toBe("unknown");
  });

  it("refuses a message of no known type", () => {
    expect(Message.safeParse({ t: "launch.missiles" }).success).toBe(false);
  });
});
