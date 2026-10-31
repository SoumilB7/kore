/**
 * The Kore phone remote's wire protocol, version 1: every message the Mac (the host) and the
 * phone exchange once their session is up. This file is the normative definition. Kore's Swift
 * (`Sources/KoreRemote/Wire`) and the phone's Kotlin link layer follow it by hand, and the
 * fixtures in `fixtures/v1` are what each of them must read and write.
 *
 * Shapes:
 * - Every message is one JSON object with its type in `t`. Host messages may carry `seq`, which
 *   the phone acknowledges with `ack`.
 * - Optional fields are omitted, never null, unless the schema says null.
 * - Enums are lenient: a value this version doesn't know reads as "unknown", so a newer host
 *   never breaks an older phone.
 * - Times are milliseconds since 1970.
 */
import { z } from "zod";

export const PROTO_MAJOR = 1;
export const PROTO_MINOR = 0;

/** A lenient enum: values this version doesn't know read as "unknown". */
function lenient<const T extends readonly [string, ...string[]]>(values: T) {
  return z.enum([...values, "unknown"] as unknown as [T[number] | "unknown", ...(T[number] | "unknown")[]]).catch("unknown");
}

// MARK: - Text as a render tree

/**
 * Text the phone shows as formatted (answers, plans, summaries). The Mac parses the markdown
 * with Kore's own parser and sends this small tree, so the phone carries no markdown parser.
 */
export const Span = z.object({
  text: z.string(),
  code: z.boolean().optional(),
  em: z.boolean().optional(),
  strong: z.boolean().optional(),
  strike: z.boolean().optional(),
  link: z.string().optional(),
});
export type Span = z.infer<typeof Span>;

export type Block =
  | { k: "heading"; level: number; spans: Span[] }
  | { k: "paragraph"; spans: Span[] }
  | { k: "code"; lang: string; text: string; open?: boolean }
  | { k: "list"; ordered: boolean; start: number; items: { task?: boolean; blocks: Block[] }[] }
  | { k: "quote"; blocks: Block[] }
  | { k: "table"; header: Span[][]; rows: Span[][][] }
  | { k: "rule" }
  | { k: "unknown" };

export const Block: z.ZodType<Block> = z.lazy(() =>
  z.union([
    z.object({ k: z.literal("heading"), level: z.number().int(), spans: z.array(Span) }),
    z.object({ k: z.literal("paragraph"), spans: z.array(Span) }),
    z.object({ k: z.literal("code"), lang: z.string(), text: z.string(), open: z.boolean().optional() }),
    z.object({
      k: z.literal("list"),
      ordered: z.boolean(),
      start: z.number().int(),
      items: z.array(z.object({ task: z.boolean().optional(), blocks: z.array(Block) })),
    }),
    z.object({ k: z.literal("quote"), blocks: z.array(Block) }),
    z.object({ k: z.literal("table"), header: z.array(z.array(Span)), rows: z.array(z.array(z.array(Span))) }),
    z.object({ k: z.literal("rule") }),
    // A block kind from a newer host: shown as nothing.
    z.object({ k: z.string() }).transform(() => ({ k: "unknown" as const })),
  ]),
);

// MARK: - Providers and modes

/**
 * How far a mode lets the agent act without asking, lowest first:
 * plan 0 < manual 1 < edits 2 < auto 3 < danger 4.
 * The phone may only lower a chat's mode, and may send only to chats at or below
 * `welcome.policy.sendMaxLevel`.
 */
export const ModeLevel = z.number().int().min(0).max(4);

export const ModeInfo = z.object({
  id: z.string(),
  label: z.string(),
  level: ModeLevel,
  listed: z.boolean(),
});

/** Everything that differs between the CLIs, as data, so the phone never branches on provider. */
export const ProviderInfo = z.object({
  id: z.string(),
  name: z.string(),
  modes: z.array(ModeInfo),
  /** A plan switch apart from the modes (Codex); null when plan is one of the modes (Claude). */
  planToggle: z.object({ id: z.string(), label: z.string() }).nullable(),
  features: z.object({ effort: z.boolean(), fastMode: z.boolean() }),
});

// MARK: - Windows, tabs, chats

export const Tab = z.object({
  id: z.string(),
  kind: lenient(["chat", "agent", "file", "board", "empty"] as const),
  title: z.string(),
  /** chat, agent: the chat (an agent tab names its parent chat). */
  chatId: z.string().optional(),
  /** board: its sections, each with the chats on it in order. */
  board: z.object({ sections: z.array(z.object({ id: z.string(), name: z.string(), chatIds: z.array(z.string()) })) }).optional(),
});

/** A folder window. `path` is home-relative ("~/Code/acme-api"). */
export const Window = z.object({
  id: z.string(),
  name: z.string(),
  path: z.string(),
  tabs: z.array(Tab),
  activeTabId: z.string().optional(),
});

export const CardAction = z.object({
  id: lenient(["allow", "allowAlways", "deny", "approvePlan", "approvePlanAcceptEdits", "keepPlanning", "implement", "stay", "submitAnswers"] as const),
  label: z.string(),
  style: lenient(["primary", "neutral", "destructive"] as const),
  /** Shown but refused from the phone (the Mac's policy). */
  refused: z.boolean().optional(),
});

export const Question = z.object({
  id: z.string(),
  text: z.string(),
  header: z.string(),
  options: z.array(z.object({ label: z.string(), description: z.string(), preview: z.string().optional() })),
  multiple: z.boolean(),
  secret: z.boolean(),
  other: z.boolean(),
});

/** Something the chat waits on the owner for. */
export const Card = z.object({
  id: z.string(),
  kind: lenient(["permission", "questions", "plan", "planReady", "signIn"] as const),
  title: z.string(),
  detail: z.string().optional(),
  body: z.string().optional(),
  bodyLen: z.number().int().optional(),
  plan: z.array(Block).optional(),
  questions: z.array(Question).optional(),
  agent: z.string().optional(),
  actions: z.array(CardAction),
});

export const ChatMeta = z.object({
  id: z.string(),
  provider: z.string(),
  title: z.string(),
  /** needsYou: a card waits; failed: the last turn failed; stuck: the connection is stuck. */
  state: lenient(["needsYou", "failed", "stuck", "working", "idle"] as const),
  mode: z.object({ id: z.string(), level: ModeLevel, planOn: z.boolean().optional() }),
  /** The modes this chat's model offers, and those the phone may switch it to (lower only). */
  modeIds: z.array(z.string()),
  allowedModeIds: z.array(z.string()),
  model: z.string().optional(),
  queued: z.number().int(),
  running: z.boolean(),
  cards: z.array(Card),
  can: z.object({ send: z.boolean(), stop: z.boolean() }),
});

// MARK: - Transcript

export const WireEntry = z.object({
  id: z.string(),
  kind: lenient(["user", "answer", "thinking", "plan", "tool", "agent", "notice", "peer", "divider", "mode", "summary"] as const),
  turn: z.string().optional(),
  /** Plain text: the user's message, a notice, a divider, a tool's header. */
  text: z.string().optional(),
  /** Formatted text: an answer, a plan, a summary. */
  doc: z.array(Block).optional(),
  /** The full text's length when `text` or `doc` was cut (`entry.more` reads the rest). */
  textLen: z.number().int(),
  done: z.boolean(),
  isError: z.boolean(),
  stopped: z.boolean(),
  inTurn: z.boolean(),
  tool: z
    .object({
      name: z.string(),
      summary: z.string().optional(),
      input: z.string().optional(),
      inputLen: z.number().int(),
      path: z.string().optional(),
      readOnly: z.boolean(),
      result: z.string().optional(),
      resultLen: z.number().int(),
    })
    .optional(),
  changes: z.array(z.object({ path: z.string(), added: z.number().int(), removed: z.number().int() })).optional(),
  agent: z.object({ id: z.string(), name: z.string(), status: z.string() }).optional(),
});

export const WireTurn = z.object({
  id: z.string(),
  startedAt: z.number(),
  duration: z.number().optional(),
  finished: z.boolean(),
  outcome: lenient(["completed", "interrupted", "failed", "authFailed", "slept"] as const),
});

// MARK: - Attention

export const AttnItem = z.object({
  /** Stable while the card waits: "<chatId>/<cardId>". */
  key: z.string(),
  chatId: z.string(),
  provider: z.string(),
  window: z.string(),
  chatTitle: z.string(),
  kind: lenient(["approval", "question", "plan", "planReady", "signIn"] as const),
  cardId: z.string(),
});

export const AttnTurn = z.object({
  chatId: z.string(),
  provider: z.string(),
  window: z.string(),
  chatTitle: z.string(),
  turnId: z.string(),
  outcome: lenient(["finished", "failed"] as const),
  at: z.number(),
});

// MARK: - Commands

export const Command = z.discriminatedUnion("type", [
  z.object({ type: z.literal("chat.send"), chatId: z.string(), text: z.string() }),
  z.object({ type: z.literal("chat.stop"), chatId: z.string() }),
  z.object({
    type: z.literal("chat.answer"),
    chatId: z.string(),
    cardId: z.string(),
    action: CardAction.shape.id,
    /** submitAnswers: question id → the labels picked, or what was typed under Other. */
    answers: z.record(z.string(), z.array(z.string())).optional(),
  }),
  z.object({ type: z.literal("chat.setMode"), chatId: z.string(), modeId: z.string() }),
  z.object({ type: z.literal("chat.setPlan"), chatId: z.string(), on: z.boolean() }),
  z.object({ type: z.literal("chat.planReady"), chatId: z.string(), choice: lenient(["implement", "stay"] as const) }),
  z.object({ type: z.literal("chat.new"), windowId: z.string(), provider: z.string() }),
]);

export const ResultCode = lenient([
  "denied.sendCap",
  "denied.raiseMode",
  "denied.alwaysAllow",
  "denied.command",
  "denied.signIn",
  "denied.action",
  "gone.chat",
  "gone.card",
  "gone.window",
  "busy",
  "invalid",
  "rateLimited",
] as const);

// MARK: - Messages

const seq = { seq: z.number().int().optional() };

export const Message = z.discriminatedUnion("t", [
  // Session
  z.object({
    t: z.literal("hello"),
    proto: z.object({ major: z.number().int(), minor: z.number().int() }),
    device: z.object({ name: z.string(), build: z.string() }),
    mode: lenient(["foreground", "background"] as const),
    attnAfter: z.number().int().optional(),
    resume: z.object({ hostEpoch: z.string(), rev: z.number().int(), subs: z.array(z.object({ chatId: z.string(), txRev: z.number().int() })) }).optional(),
  }),
  z.object({
    t: z.literal("welcome"),
    ...seq,
    proto: z.object({ major: z.number().int(), minor: z.number().int() }),
    hostEpoch: z.string(),
    host: z.object({ name: z.string(), koreVersion: z.string() }),
    providers: z.array(ProviderInfo),
    policy: z.object({ sendMaxLevel: ModeLevel }),
    caps: z.array(z.string()),
  }),
  z.object({ t: z.literal("presence"), mode: lenient(["foreground", "background"] as const), visibleChat: z.string().optional() }),
  z.object({ t: z.literal("ack"), seq: z.number().int() }),
  z.object({ t: z.literal("bye"), ...seq, reason: lenient(["sleep", "off", "removed", "quit", "replaced"] as const) }),

  // State
  z.object({ t: z.literal("snapshot"), ...seq, rev: z.number().int(), windows: z.array(Window), chats: z.array(ChatMeta) }),
  z.object({
    t: z.literal("delta"),
    ...seq,
    rev: z.number().int(),
    /** Every window again, when any of them changed. */
    windows: z.array(Window).optional(),
    chats: z.array(ChatMeta).optional(),
    removed: z.array(z.string()).optional(),
  }),

  // Transcripts
  z.object({ t: z.literal("tx.open"), chatId: z.string(), last: z.number().int().optional() }),
  z.object({ t: z.literal("tx.more"), chatId: z.string(), count: z.number().int() }),
  z.object({ t: z.literal("tx.close"), chatId: z.string() }),
  z.object({
    t: z.literal("tx.page"),
    ...seq,
    chatId: z.string(),
    txRev: z.number().int(),
    entries: z.array(WireEntry),
    turns: z.array(WireTurn),
    hasEarlier: z.boolean(),
  }),
  z.object({
    t: z.literal("tx.delta"),
    ...seq,
    chatId: z.string(),
    txRev: z.number().int(),
    upserts: z.array(WireEntry),
    removed: z.array(z.string()),
    /** The window's entry ids in order, when anything but an append changed it. */
    order: z.array(z.string()).optional(),
    turns: z.array(WireTurn).optional(),
    hasEarlier: z.boolean().optional(),
  }),
  z.object({ t: z.literal("tx.reset"), ...seq, chatId: z.string() }),
  z.object({
    t: z.literal("entry.more"),
    id: z.string(),
    chatId: z.string(),
    entryId: z.string(),
    field: lenient(["text", "input", "result"] as const),
    offset: z.number().int(),
  }),
  z.object({
    t: z.literal("entry.chunk"),
    ...seq,
    id: z.string(),
    text: z.string(),
    offset: z.number().int(),
    total: z.number().int(),
  }),

  // Commands
  z.object({ t: z.literal("cmd"), id: z.string(), cmd: Command }),
  z.object({ t: z.literal("result"), ...seq, id: z.string(), ok: z.boolean(), code: ResultCode.optional(), message: z.string().optional() }),

  // Attention
  z.object({ t: z.literal("attn.state"), ...seq, aid: z.number().int(), open: z.array(AttnItem), recent: z.array(AttnTurn) }),
  z.object({
    t: z.literal("attn.event"),
    ...seq,
    aid: z.number().int(),
    op: lenient(["open", "clear", "turn"] as const),
    item: AttnItem.optional(),
    key: z.string().optional(),
    turn: AttnTurn.optional(),
  }),
]);
export type Message = z.infer<typeof Message>;

/** Every message type, for the fixture manifest's coverage check. */
export const MESSAGE_TYPES = Message.options.map((o) => o.shape.t.value);
