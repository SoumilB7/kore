# Link 1.4 to 1.7: the box (`kore-host`)

A box is a headless machine running `kore-host`: the Mac reaches it with
`ssh <box> ~/.local/bin/kore-host attach --as <grant>`. Everything in link 1.0–1.3 holds unless this page says
otherwise. All additions are optional fields or new command types, so a 1.3 peer ignores them.

## Grants

- `kore-host allow <name> [--control watch|act|full]` writes
  `${XDG_STATE_HOME:-~/.local/state}/kore-host/grants/<name>.json` (folder 0700, file 0600):
  `{"v":1,"name","socket","secret":"<base64, 32 bytes>","control","created":<unix s>}`.
  On macOS the folder is `~/Library/Application Support/kore-host/grants/` unless `XDG_STATE_HOME` is set.
- `revoke <name>` deletes it. The daemon reads a connection's grant again on each command: once
  the file is gone or holds a new secret (`allow` again), the connection ends with `bye auth`; a
  lowered `--control` holds from the next command.
  `grants` lists names and control, never secrets.
- Control: `watch` reads only (every `cmd` is `denied.control`); `act` sends, stops, answers,
  sets mode, plan, model, makes chats and adds folders; `full` adds the `account.*` commands.

## Socket and handshake

- `$XDG_RUNTIME_DIR/kore-host/link.sock` (folder 0700, socket 0600; `/run/user/<uid>` when
  `XDG_RUNTIME_DIR` isn't set), listening while the daemon runs. One daemon per folder: it holds
  `run.lock` there, and a second `run` exits without touching the socket. The peer's uid must be
  the host's. Several grants may be connected at once. A newer proven connection for a grant
  already connected takes over: the older one gets `bye replaced` (a link that died while the Mac
  slept never locks it out). A client told `replaced` doesn't dial again.
- Writes to a client never block the daemon: each connection queues what its peer hasn't read,
  and one more than 8 MiB behind is closed (a 1.5 follower catches up by `seq` when it's back; a
  `tx` client gets a fresh page).
- Framing, `challenge` and `hello` are as in link 1.0, with `hello.grant: "<name>"`. The proof is
  `HMAC-SHA256(grant secret, "kore-link/1|" + nonce)`. Unknown grant or bad proof: `bye auth`.
- `attach --as <name>` reads the grant, passes frames between stdin/stdout and the socket, and
  fills in `grant` and `proof` on the client's first `hello` (send it with `"proof": ""`).
- `attach` exits 3 when no daemon listens, 4 when there's no such grant, 5 when there's no
  runtime folder, 2 on bad arguments; over ssh, 255 is ssh's own failure and 126/127 the shell's
  (kore-host can't run there, or isn't there).
- `welcome`: `proto {1,7}`, `host {name, koreVersion (kore-host's version), kind: "box"}`,
  `policy {sendMaxLevel: 4, control: "full"|"standard"}` (`full` for a full grant),
  `caps ["tx","attn","commands","control","box"]`, plus `"stream"` for a full grant (1.5). For a
  full grant each of `providers[]` carries `calls`: the `chat.call` types the box takes for that
  CLI. Then `snapshot` and an empty `attn.state`.
- There is no link ping: the Mac's `ssh` notices a dead link itself (`-o ServerAliveInterval=15
  -o ServerAliveCountMax=2`), so the box never wakes to answer one.

## State

- Windows are the box's folders: `{id: "w_<hash of path>", name, path ("~/…"), tabs, activeTabId}`.
  Tabs are the folder's chats, `{id: "t_<chatId>", kind: "chat", title, chatId}`.
- `ChatMeta` as in link 1.0, with no `rescue` or `arsenal`. A chat's meta goes out only when it changed.
  A chat whose mode isn't one its CLI lists counts as Danger. `state` is `needsYou`, `working` or `idle`.
- With a `full` grant, `ChatMeta.controls` as in link 1.2: `{modelId, effort, fast, fastOffered,
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
  `card.more` for the rest). The digest is as in link 1.0.

## Transcripts

- As in link 1.0, with no rendering on the box: answers, plans and summaries carry `text`, never `doc`.
  The client renders markdown.
- `tx.open` never starts a CLI; it answers from the chat's log at once, a restarted box included.
- When a chat's CLI resumes (its first send after a restart or an idle stop), the log keeps what
  it had and goes on from there: the history the CLI reads in is neither sent again nor cut to
  the CLI's page of it. A rollback or a corrected history replaces the log (`tx.reset`, then a
  page with new ids). Streaming text goes to the log once it's done; a torn last line is skipped
  on reading. A page's frame stays under 900 KiB: fewer of the newest entries when they don't fit.
- `entry.more` reads from the live chat only; for a chat whose CLI is stopped it answers
  `result {id, ok: false, code: "gone.chat"}`.
- No `tx.earlier`, `history.*`, `diff.get` or `blob.get` on the box. A `tx` client's `chat.send`
  with `blobs` is `invalid`; a 1.5 full grant uploads with `blob.put.*` (see Calls below).

## Commands (1.4 additions)

| `type` | fields | |
|---|---|---|
| `chat.new` | `folder, provider, modelId?, mode?, level?, title?, sessionId?, entryId?` | `folder` (an absolute path the box serves) in place of `windowId`; `windowId` still works. Result: `chatId`, `windowId`. 1.5: `mode` and `level` (effort) to start on, and a fork's start (`sessionId` and the message `entryId`). A `mode` above Manual (`act`) or above Auto (`full`), or one the CLI doesn't list, is `denied.raiseMode`. |
| `chat.close` | `chatId` | The tab closed: the chat leaves the box's windows (`delta` with `removed`) and its CLI ends. Its record and logs stay on disk, marked closed. 1.5 clients close through `chat.call close`. |
| `chat.setModel` | `chatId, modelId` | Also for an `act` grant. A chat whose CLI isn't running starts on that model. The model must be one the box's CLI listed (or, before any list, a plain id of letters, digits and `._:[]-`, at most 128); `invalid` otherwise. |
| `chat.setEffort` | `chatId, level` | Also for an `act` grant. A running CLI switches; a stopped one starts on it. `invalid` when the chat's models offer no such level. |
| `chat.setFast` | `chatId, on` | Also for an `act` grant. Only while the chat's CLI runs and has said fast mode is there for its model; `invalid` otherwise. |
| `chat.setMode`, `chat.setPlan`, `chat.planReady`, `chat.answer approvePlanAcceptEdits` | as in link 1.0 | A `full` grant is full control, which may raise a chat's mode up to Auto (Auto, Approve for me, leaving plan, approving with auto-accept edits), the same rule as the Mac's link under full control (1.2). Bypass, Codex's Full access and unknown modes stay refused to every client; `watch` and `act` stay lower-only (`denied.raiseMode`). Under full control `ChatMeta.allowedModeIds` lists every mode up to Auto, and a plan card's `approvePlanAcceptEdits` isn't marked `refused`. Always allow and `!` lines stay refused. |
| `folders.list` | | Result: `folders: [{windowId, path, missing?}]`; `missing: true` for a served folder that isn't there any more. |
| `folder.add` | `path` | An existing folder, by absolute path or under `~` (the box's home); it's added to `config.json`. Result: `folders`. `gone.folder` otherwise. |
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

## Two-way sync

A Mac folder can have a copy on the box that the Mac keeps in sync both ways while that copy's
window is open. The Mac moves the files with rsync over SSH; the box only says what changed.

| `type` | fields | |
|---|---|---|
| `sync.watch` | `folder` | An absolute folder the box serves (or one inside it); `act` or `full` grant; at most 4 per connection (`busy` past that). Result: `ok`. Then the folder's whole list follows as `sync.changed` with `all: true` (in pieces of at most 2000, `more: true` on all but the last, each sent once the socket has drained), then its changes while this connection lasts. Sent again, it lists again. |
| `sync.unwatch` | `folder` | Ends that watch. A connection's watches also end with it. |

`sync.changed {folder, paths: [{p, s, m} | {p, gone: true}], all?, more?, watching?, limit?, folders?, missing?, capped?}`
goes from the box unasked. `p` is the path from `folder`, `s` the size in bytes, `m` the mtime in
whole seconds; a folder that went is one `gone` entry. Changes are gathered for 300 ms and sent
as one message.

- Left out on both ends: `.git/`, `.build/`, `node_modules/`, `.DS_Store`, and what each folder's
  `.gitignore` names. Only regular files are listed.
- Linux watches with inotify, one watch per folder. When the folder has more folders than half of
  `fs.inotify.max_user_watches`, the box doesn't watch it: the whole list carries
  `watching: false`, `limit` and `folders` (counted up to half the limit plus one), and the Mac
  sends `sync.watch` again when it wants a fresh list (its window comes forward, a turn ends).
  Nothing polls.
- macOS (tests) watches with FSEvents.
- The list is built in one walk off the daemon's main thread. A folder that isn't there sends one
  `all` with `missing: true` and no paths; one with more than 200,000 files sends `capped: 200000`
  and no paths. Neither is an empty list.
- Nothing is listed or watched through a symlink: links are skipped at every level.
- The Mac checks every `p` before using it: relative, no empty, `.` or `..` part, no control
  character, and no symlinked folder on its own side. Anything else is dropped. It never deletes in
  bulk on its own: a missing or empty side, or a round that would delete more than half of what
  was agreed (10 files or more), waits for the user.

## GitHub

`ghSignedIn` (whether `gh auth status` succeeds for github.com) is in `welcome.host` and in the
`snapshot` (beside `windows` and `chats`). It's read off the daemon's main thread on a connect (at
most once a minute) and after `auth.gh`, never polled; a change goes out as a `delta`.

## CLIs

- A box chat's CLI starts with one paragraph saying it runs on the box through kore-host, seen as
  a tab in Kore on the Mac, and that Kore's tools are available when the user turns Arsenal on for
  the chat. It has no `kore` helper on its PATH; while Arsenal is on, it has the `kore_app` MCP
  server (1.6, below).

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
- `requestUsage {id, at, model?, agent?, input, output, cacheRead, cacheWrite5m, cacheWrite1h}`:
  one model request's tokens, as the CLI reported it live. The Mac weighs each as its own usage
  index does and keeps it (`usage/forwarded.json`, a week, once per chat and request id), so
  Kore's share of the plan's limits counts the box's chats as Kore's; the chat doesn't show it.
  The box keeps no usage record of its own.
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
  `setRemoteControl {on}`, `relaunch {reason}`, `listModels`, `close` (the tab closed, as
  `chat.close`), and `keepRow {text, id}` (a typed /compact's row, which the CLI isn't sent: the
  box's chat and log keep it; only a /compact row is taken). A type the box doesn't know reads as unknown and is refused `invalid`.
- The answer is a `result {id, ok, code?, message?, value?}`. `value` holds the call's one return:
  `bool` (send: a turn is under way), `text`, `events` and `more` (agent history, earlier pages,
  rollback), `forkFrom`/`forkAt` (a fork's start; none for a fresh chat), `messages`,
  `unloadEarlier`, `models`, `reading` (usage), `outcome` (a reset).
- The box runs each on the chat's real backend, and keeps its own chat in step where it holds
  state: a message goes through its chat (its row, its queue), an answer through its approvals, a
  mode, model or effort into its controls and record, a rollback into its history.
- Files: the client uploads each with `blob.put.*` (1.1, full grants) and names its blob in
  `send.files`; the box saves it under `state/uploads/<blob>/` and the CLI gets that path.
  Uploads older than a day go when the daemon starts and before each new one, and together they
  take at most 200 MiB (the oldest go first).
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

## Link 1.6: Arsenal on a box

A box chat's agent uses Kore's `kore_app` tools on the Mac, as a Mac chat's does, under the tier
and limits the Mac holds for that chat. All of it is additive: a 1.5 peer ignores the new fields
and never sees the new messages.

### The tier

- `chat.call` with a `send` carries `arsenal`: the chat's tier on the Mac (`watch`, `own` or
  `drive`; absent for off), and `note`: the line the Mac owes the agent when the tier changed
  since it was last told (`Kore note: Arsenal is now …`). The box takes a `note` only in that
  form, at most 400 characters, and gives it to the CLI before the message.
- `chat.follow` carries `arsenal` too: a chat whose CLI starts for that follow starts with it.
- While the tier isn't off, kore-host starts the chat's CLI with the `kore_app` MCP server,
  `kore-host mcp`, and instructions saying what its tools do; claude's are allowed without asking
  (`--allowedTools`), and codex's run without an approval (`default_tools_approval_mode`). A
  message whose tier turns the server on or off finds the CLI idle and starts it again (the
  session resumes); a CLI at work keeps what it has until a message finds it idle.
- The tier decides nothing on the box: it says only whether the server is there.

### Calls

- `kore-host mcp` lists the same tools and schemas as the Mac's `kore mcp`, and `kore_new_chat`
  takes `place`: `box` (the default: the same box and folder) or `mac` (the Mac window of the
  folder this one syncs with, else the Mac's front window).
- Its environment holds `KORE_AGENT_CHAT` (the box chat's id), `KORE_AGENT_PASS` (a secret made
  for that CLI's run) and `KORE_AGENT_SOCKET` (`$XDG_RUNTIME_DIR/kore-host/agent.sock`, 0600 in
  the runtime folder). Each call is one connection there: one frame
  `{"t": "agent.ask", chatId, pass, tool, args}` (framed as the link is), answered with one
  `{"t": "agent.result", ok, code?, text}`. A pass that isn't the one that chat's running CLI was
  given is refused there, and goes nowhere.
- `agent.call {id, chatId, tool, args}`, box to client, full grants only: kore-host passes the
  call to the full grant that follows the chat, else the last full grant to connect. With none,
  the answer is "Kore isn't connected to <box> right now"; a link that ends, or 30 s with no
  answer (330 s for `kore_wait`, 75 s for `kore_fork`), ends the call so too.
- `agent.result {id, ok, code?, text}`, client to box: `text` is what the agent reads, the
  command's data as JSON or why not. `code` is the agent channel's (`denied`, `tier`, `limit`,
  `no_chat`, …). The box takes an answer only from the connection the call went to.
- The Mac answers a call only for its own tab of that chat on that box (`no_chat` otherwise), and
  only at that chat's tier: off is `denied`, a tool above it is `tier`. Its limits are that
  chat's, counted with everything else it does: 30 commands a minute, 10 messages a minute, 10 new
  chats an hour and 6 of them open, wherever they opened.


## Link 1.7: a box's files

The Mac's box window shows the box folder's files, and its Welcome browses the box for a folder
to open. Three read-mostly commands, full grants only (`denied.control` otherwise), each checked
by `LinkPolicy.checkBox` and answered off the daemon's main thread. A 1.6 box answers them
`invalid`; the Mac says the box needs an update.

| `type` | fields | |
|---|---|---|
| `fs.list` | `path?, hidden?` | A folder's entries: `{name, kind: "dir"\|"file"\|"link", size? (files), dir? (a link to a folder)}`, folders first, then by name; dotfiles only with `hidden: true`. At most 5,000 (`more: true` past that). No `path`: the box's home. Result: `path` (normalised), `entries`, `more?`. |
| `fs.read` | `path, max?` | A file in a served folder, at most `max` bytes (2 MiB, and never more). Result: `kind` (`text`, `image` or `binary`), `size`, and `text` (UTF-8; a character cut at the end is dropped) or `data` (an image's bytes in base64; none for an image past `max`), `truncated: true` when it was cut. A binary file carries neither. |
| `fs.mkdir` | `path` | One new folder whose parent may be listed (the browser's New Folder). Result: `path`. |

Where a path may lead:

- Every `path` is absolute, with no NUL or newline, at most 4096 bytes. `.` and `..` are resolved
  before any check, so a path can't climb out of where it starts.
- `fs.list` and `fs.mkdir`: inside the box user's home, or inside a folder the box serves (one
  added on purpose with `folder.add`, wherever it is). Anything else, `/` included, is
  `denied.path`: the browser starts at the home and goes outside it only through a served folder.
  A path typed in the browser still opens (`folder.add`) without being listed.
- `fs.read`: inside a served folder only.
- Links are listed as `link` and never followed out: the path's real place (its links
  resolved) has to stay inside the home or served folder it's under, else `denied.path`. A link
  that stays inside is read as what it leads to.
- A path that isn't there is `gone.file`; a file where a folder is wanted (or the reverse) is
  `invalid`.

The Mac asks only while a window or the browser shows the files: a box window lists the
folders open in its explorer, and lists them again when a turn in that window ends. The box
watches nothing for it and nothing polls.

Also 1.7: `account.refresh`'s result and a sign-in's `<id>:done`, when `signedIn: true`, carry
`account: {email?, plan?, organization?, method, changeable, methodID?, platform?}` (who the
CLI there is signed in as, never a token), so a box chat's Account popup reads as a local one's.
