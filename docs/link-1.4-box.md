# Link 1.4 and 1.5: the box (`kore-host`)

§13 of the link protocol. A box is a headless machine running `kore-host`: the Mac reaches it with
`ssh <box> kore-host attach --as <grant>`. Everything in link 1.0–1.3 holds unless this page says
otherwise. All additions are optional fields or new command types, so a 1.3 peer ignores them.

## Grants

- `kore-host allow <name> [--control watch|act|full]` writes
  `${XDG_STATE_HOME:-~/.local/state}/kore-host/grants/<name>.json` (folder 0700, file 0600):
  `{"v":1,"name","socket","secret":"<base64, 32 bytes>","control","created":<unix s>}`.
  On macOS the folder is `~/Library/Application Support/kore-host/grants/` unless `XDG_STATE_HOME` is set.
- `revoke <name>` deletes it; the daemon (signalled) closes that grant's connection with `bye auth`.
  The daemon also reads the grant file again before each command, so a revoked, re-made or lowered
  grant takes effect at its next command without a signal.
  `grants` lists names and control, never secrets.
- Control: `watch` reads only (every `cmd` is `denied.control`); `act` sends, stops, answers,
  sets mode, plan, model, makes chats and adds folders; `full` adds the `account.*` commands.

## Socket and handshake

- `$XDG_RUNTIME_DIR/kore-host/link.sock` (folder 0700, socket 0600), listening while the daemon
  runs. The peer's uid must be the host's. Several grants may be connected at once. A newer proven
  connection for a grant already connected takes over: the older one gets `bye replaced` (a link
  that died while the Mac slept never locks it out). A client told `replaced` doesn't dial again.
- Writes to a client never block the daemon: each connection queues what its peer hasn't read,
  and one more than 8 MiB behind is closed (it catches up by `seq` when it's back).
- Framing, `challenge` and `hello` are as §2–3, with `hello.grant: "<name>"`. The proof is
  `HMAC-SHA256(grant secret, "kore-link/1|" + nonce)`. Unknown grant or bad proof: `bye auth`.
- `attach --as <name>` reads the grant, passes frames between stdin/stdout and the socket, and
  fills in `grant` and `proof` on the client's first `hello` (send it with `"proof": ""`).
- `welcome`: `proto {1,5}`, `host {name, koreVersion, kind: "box"}`,
  `policy {sendMaxLevel: 4, control: "full"|"standard"}` (`full` for a full grant),
  `caps ["tx","attn","commands","control","box"]`, plus `"stream"` for a full grant (1.5). For a
  full grant each of `providers[]` carries `calls`: the `chat.call` types the box takes for that
  CLI. Then `snapshot` and an empty `attn.state`.
- There is no link ping: the Mac's `ssh` notices a dead link itself (`-o ServerAliveInterval=15
  -o ServerAliveCountMax=2`), so the box never wakes to answer one.

## State

- Windows are the box's folders: `{id: "w_<hash of path>", name, path ("~/…"), tabs, activeTabId}`.
  Tabs are the folder's chats, `{id: "t_<chatId>", kind: "chat", title, chatId}`.
- `ChatMeta` as §4, with no `rescue` or `arsenal`. A chat's meta goes out only when it changed.
  A chat whose mode isn't one its CLI lists counts as Danger. `state` is `needsYou`, `working` or `idle`.
- With a `full` grant, `ChatMeta.controls` as §11: `{modelId, effort, fast, fastOffered,
  planAllow, contextPct, autoCompactAt, compacting, remote}`, plus two 1.4 fields,
  `contextUsed` (tokens in context) and `contextWindow` (what they're measured against), both
  absent until the CLI says. `contextPct` is `contextUsed * 100 / contextWindow`, at most 100.
  While a chat's CLI is stopped, its controls are as the live chat last had them (kept in its
  `meta.json`), with `compacting: false`; a chat that never ran has the `modelId` and `effort`
  it will start on. `act` and `watch` grants get no `controls`.
- With a `full` grant, the `snapshot` carries `clis: [{provider, models: [{id, name, efforts,
  fast, auto}], effortScale}]` (no `account`): each CLI's models as the box's own CLI listed
  them, `effortScale` every effort its models offer, lowest first. Only CLIs that have listed
  are there; with none, `clis` is absent. A new list goes to full grants as a `delta` with
  `clis` (the whole array) and nothing else.
- The lists come only from a CLI already running: the list its session starts with, and a turn's
  end asking it again (the claude CLI's `list_models` control request, the codex CLI's `model/list`) at most
  once per 10 minutes per CLI. No CLI starts for a list and nothing polls. The last lists are
  kept in `${XDG_STATE_HOME:-~/.local/state}/kore-host/models.json` (0600), so a connection
  gets them in its snapshot before any CLI runs.
- Cards: a plan card's `plan` is absent; the plan's markdown is in `body` (4 KiB cut,
  `card.more` for the rest). The digest is as §4.

## Transcripts

- As §5, with no rendering on the box: answers, plans and summaries carry `text`, never `doc`.
  The client renders markdown.
- `tx.open` never starts a CLI; it answers from the chat's log at once, a restarted box included.
- When a chat's CLI resumes (its first send after a restart or an idle stop), the history it
  reads in replaces the log: the box sends `tx.reset` and a new `tx.page` (entry ids change).
  Streaming text goes to the log once it's done; a torn last line is skipped on reading.
- `entry.more` reads from the live chat only; for a chat whose CLI is stopped it answers
  `result {id, ok: false, code: "gone.chat"}`.
- No `tx.earlier`, `history.*`, `diff.get`, `blob.*` on the box (uploads: `chat.send` with `blobs`
  is `invalid`).

## Commands (1.4 additions)

| `type` | fields | |
|---|---|---|
| `chat.new` | `folder, provider, modelId?, mode?, level?, title?, sessionId?, entryId?` | `folder` (an absolute path the box serves) in place of `windowId`; `windowId` still works. Result: `chatId`, `windowId`. 1.5: `mode` and `level` (effort) to start on, and a fork's start (`sessionId` and the message `entryId`). A `mode` above Manual (`act`) or above Auto (`full`), or one the CLI doesn't list, is `denied.raiseMode`. |
| `chat.close` | `chatId` | The tab closed: the chat leaves the box's windows (`delta` with `removed`) and its CLI ends. Its record and logs stay on disk, marked closed. 1.5 clients close through `chat.call close`. |
| `chat.setModel` | `chatId, modelId` | Also for an `act` grant. A chat whose CLI isn't running starts on that model. The model must be one the box's CLI listed (or, before any list, a plain id of letters, digits and `._:[]-`, at most 128); `invalid` otherwise. |
| `chat.setEffort` | `chatId, level` | Also for an `act` grant. A running CLI switches; a stopped one starts on it. `invalid` when the chat's models offer no such level. |
| `chat.setFast` | `chatId, on` | Also for an `act` grant. Only while the chat's CLI runs and has said fast mode is there for its model; `invalid` otherwise. |
| `chat.setMode`, `chat.setPlan`, `chat.planReady`, `chat.answer approvePlanAcceptEdits` | as §6 | A `full` grant is full control, which may raise a chat's mode up to Auto (Auto, Approve for me, leaving plan, approving with auto-accept edits), the same rule as the Mac's link (§11). Bypass, Codex's Full access and unknown modes stay refused to every client; `watch` and `act` stay lower-only (`denied.raiseMode`). Under full control `ChatMeta.allowedModeIds` lists every mode up to Auto, and a plan card's `approvePlanAcceptEdits` isn't marked `refused`. Always allow and `!` lines stay refused. |
| `folders.list` | | Result: `folders: [{windowId, path}]`. |
| `folder.add` | `path` | An absolute path to an existing folder; it's added to `config.json`. Result: `folders`. `gone.folder` otherwise. |
| `account.refresh` | `provider` | Result `message`: "Signed in as …" / "… isn't signed in.". |
| `account.signIn` | `provider, method?` | Result `message`: the page to open (and `code …` for a device code), space-separated. When the sign-in ends: `result {id: "<id>:done", ok, message}`. |
| `account.submit` | `provider, serial, input` | The code from the page. |
| `account.cancel`, `account.signOut` | `provider` | |

| `auth.gh` | | `gh auth login --web` on the box. Result: `url` and `authCode` (the one-time code to type at `url`; `code` stays the error field). When it ends: `result {id: "<id>:done", ok}`, `gh auth setup-git` run, and a `delta` with `ghSignedIn`. |

Every control command goes through the box's rule table (`LinkPolicy.checkBox`); all other
1.2/1.3 commands are `invalid` on the box. `account.*` and `auth.gh` need a `full` grant.
`account.signIn` takes only the box's no-browser flows, and uses them without `method`: Codex's
device code (`chatgptDeviceCode`: open `url`, type the code) and Claude's page (`claudeai`: open
the page, then send the code it shows with `account.submit`). No message carries a key.

Answering a plan card into the chat's own mode, or "Implement this plan?" through `chat.answer`,
leaves plan: it follows `chat.planReady`'s rule (only where tools still ask, or up to Auto with
full control).

## GitHub

`ghSignedIn` (whether `gh auth status` succeeds for github.com) is in `welcome.host` and in the
`snapshot` (beside `windows` and `chats`). It's read off the daemon's main thread on a connect (at
most once a minute) and after `auth.gh`, never polled; a change goes out as a `delta`.

## CLIs

- A box chat's CLI has none of Kore's own tools: no `kore` helper, no MCP server, no Arsenal
  notes. It starts with one paragraph saying it runs on the box through kore-host, seen as a tab
  in Kore on the Mac.

- A chat's CLI starts on its first send (or, 1.5, the first time a full grant follows a chat with
  nothing in its event log) and stops after 10 minutes with nothing to do: no turn, queue, card,
  live background command or armed scheduled job. The next send resumes the session. At most 3
  run at once: a send past that stops the least recently used idle one, else answers `busy`.
- kore-host keeps none of the Mac app's bookkeeping (its logs, usage index, plan snapshots,
  sessions list).

## Link 1.5: box parity

A full grant drives a box's chat as the Mac's own `Chat` drives a local CLI: every `ChatBackend`
call crosses as one `chat.call`, and the backend's own `ChatEvent`s come back as `chat.events`,
so the Mac's chat, transcript and stores take them as a local chat's. `watch` and `act` grants
keep the `tx.*` projection above. Policy stays on the box, in `LinkPolicy`.

### Events

- `chat.follow {chatId, after?, log?}`: send this chat's events after seq `after` of log `log`.
  The box answers with `chat.events`. A client that names no log, another log, or a seq outside
  what the box keeps (snapshot required) gets the whole kept log, its first frame marked `reset`:
  what it held is replaced. `chat.unfollow {chatId}` stops them. An unknown chat: `result
  {id: "chat.follow:<chatId>", ok: false, code: "gone.chat"}`.
- `chat.events {chatId, log, reset?, items: [{s, e?, open?, close?, by?}]}`: `s` is the item's
  seq, rising by one per item within a log. `e` is one `ChatEvent`; a history (`replayed`,
  `historyReplaced`) is sent piece by piece, `open: "replayed"|"historyReplaced"`, its events,
  then `close: true`. `by` names the grant whose own `chat.call` made a row (a message's
  `userMessage`/`messageQueued`, an answered card's `approvalWithdrawn`); that client already
  shows it. Frames stay under 512 KiB; a catch-up goes a part at a time as the socket drains, and
  an event too large for a frame has its long text cut.
- Events are the backend's own, sent once, unrendered. Streamed text, tool output and command
  output arriving together go as one event, at most 30 times a second per chat; nothing else
  waits. No timer runs while a chat is quiet.
- The log is `chats/<id>/events.jsonl` (0600): a header `{"log": <id>}`, then one item per line.
  It starts at the chat's first history or first event. A CLI resumed after an idle stop replays
  its session, and the box doesn't send or keep that again; the log starts again (a new id, a
  `reset` to followers) only when a rollback cuts the history or a resumed history finds the log
  past 16 MiB. A box that stopped mid-turn ends the turn in the log (`turnFinished`,
  `interrupted`) when it next reads it, and a CLI stopped mid-turn does the same.

### Calls

- `chat.call {id, chatId, command}`, full grants only (`denied.control` otherwise). `id` is the
  client's own; the box keeps each grant's last 64 answers per chat and answers a repeat with the
  first answer without running it again, so a call sent again after a dropped link runs once.
- `command` is `{"type": <call>, …fields}`, one per `ChatBackend` call: `send {text, files:
  [{blob, name, kind}], queued?, id?}`, `interrupt`, `respond {approval, decision}`, `setMode
  {id}`, `setPlanMode {on}`, `setModel {id}`, `setEffort {level}`, `setFastMode {on}`, `rename
  {title}`, `stopAgent {id}`, `stopCommand {id}`, `backgroundCommand {id}`, `commandOutput {id}`,
  `watchCommands {on}`, `agentHistory {id}`, `fork {message?, text}`, `forkAtEnd`, `rollback
  {message?, text}`, `earlier {turns?}`, `earlierMessages`, `unloadPoint {message?, text}`,
  `unloaded {earlier}`, `compact {instructions}`, `usage`, `useReset {credit?, attempt}`,
  `setRemoteControl {on}`, `relaunch {reason}`, `listModels`, and `close` (the tab closed, as
  `chat.close`). A type the box doesn't know reads as unknown and is refused `invalid`.
- The answer is a `result {id, ok, code?, message?, value?}`. `value` holds the call's one return:
  `bool` (send: a turn is under way), `text`, `events` and `more` (agent history, earlier pages,
  rollback), `forkFrom`/`forkAt` (a fork's start; none for a fresh chat), `messages`,
  `unloadEarlier`, `models`, `reading` (usage), `outcome` (a reset).
- The box runs each on the chat's real backend, and keeps its own chat in step where it holds
  state: a message goes through its chat (its row, its queue), an answer through its approvals, a
  mode, model or effort into its controls and record, a rollback into its history.
- Files: the client uploads each with `blob.put.*` (1.1, full grants) and names its blob in
  `send.files`; the box saves it under `state/uploads/<blob>/` and the CLI gets that path.
  Uploads older than a day go when the daemon starts and before each new one.
- Policy, one exhaustive rule per call (`LinkPolicy.check(ChatCommand)`): `send` as `chat.send`
  (no `!` lines, the chat's own `/` commands only); `setMode` and `setPlanMode` off up to Auto;
  `respond` never Always allow, never a sign-in card, and approving a plan into the chat's own
  mode only as leaving plan allows; `setRemoteControl` is refused (turned on on the box itself),
  and so it isn't in `providers[].calls`.

### Wire forms

`ChatEvent`, `ChatCommand` and the enums inside them are written as `{"type": <tag>, <field>:
…}` with every tag and key spelled out (`ChatEvent+Coding.swift`), so a renamed Swift case never
changes the wire. An event this side can't read is skipped; one inside a history leaves the rest.
`Tests/Fixtures/stream/v1` holds every case's form.
