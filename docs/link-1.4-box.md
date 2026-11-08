# Link 1.4: the box (`kore-host`)

§13 of the link protocol. A box is a headless machine running `kore-host`: the Mac reaches it with
`ssh <box> kore-host attach --as <grant>`. Everything in link 1.0–1.3 holds unless this page says
otherwise. All additions are optional fields or new command types, so a 1.3 peer ignores them.

## Grants

- `kore-host allow <name> [--control watch|act|full]` writes
  `${XDG_STATE_HOME:-~/.local/state}/kore-host/grants/<name>.json` (folder 0700, file 0600):
  `{"v":1,"name","socket","secret":"<base64, 32 bytes>","control","created":<unix s>}`.
  On macOS the folder is `~/Library/Application Support/kore-host/grants/` unless `XDG_STATE_HOME` is set.
- `revoke <name>` deletes it; the daemon (signalled) closes that grant's connection with `bye auth`.
  `grants` lists names and control, never secrets.
- Control: `watch` reads only (every `cmd` is `denied.control`); `act` sends, stops, answers,
  sets mode, plan, model, makes chats and adds folders; `full` adds the `account.*` commands.

## Socket and handshake

- `$XDG_RUNTIME_DIR/kore-host/link.sock` (folder 0700, socket 0600), listening while the daemon
  runs. The peer's uid must be the host's. Several grants may be connected at once; a second
  connection for a grant already connected is closed with `bye invalid`.
- Framing, `challenge` and `hello` are as §2–3, with `hello.grant: "<name>"`. The proof is
  `HMAC-SHA256(grant secret, "kore-link/1|" + nonce)`. Unknown grant or bad proof: `bye auth`.
- `attach --as <name>` reads the grant, passes frames between stdin/stdout and the socket, and
  fills in `grant` and `proof` on the client's first `hello` (send it with `"proof": ""`).
- `welcome`: `proto {1,4}`, `host {name, koreVersion, kind: "box"}`,
  `policy {sendMaxLevel: 4, control: "full"|"standard"}` (`full` for a full grant),
  `caps ["tx","attn","commands","control","box"]`. Then `snapshot` and an empty `attn.state`.

## State

- Windows are the box's folders: `{id: "w_<hash of path>", name, path ("~/…"), tabs, activeTabId}`.
  Tabs are the folder's chats, `{id: "t_<chatId>", kind: "chat", title, chatId}`.
- `ChatMeta` as §4, with no `controls`, `rescue` or `arsenal`. `state` is `needsYou`, `working`
  or `idle`.
- Cards: a plan card's `plan` is absent; the plan's markdown is in `body` (4 KiB cut,
  `card.more` for the rest). The digest is as §4.

## Transcripts

- As §5, with no rendering on the box: answers, plans and summaries carry `text`, never `doc`.
  The client renders markdown.
- `tx.open` never starts a CLI; it answers from the chat's log at once, a restarted box included.
- When a chat's CLI resumes (its first send after a restart or an idle stop), the history it
  reads in replaces the log: the box sends `tx.reset` and a new `tx.page` (entry ids change).
- `entry.more` reads from the live chat only; for a chat whose CLI is stopped it answers
  `result {id, ok: false, code: "gone.chat"}`.
- No `tx.earlier`, `history.*`, `diff.get`, `blob.*` on the box (uploads: `chat.send` with `blobs`
  is `invalid`).

## Commands (1.4 additions)

| `type` | fields | |
|---|---|---|
| `chat.new` | `folder, provider, modelId?` | `folder` (an absolute path the box serves) in place of `windowId`; `windowId` still works. Result: `chatId`, `windowId`. The CLI starts on the first send. |
| `chat.setModel` | `chatId, modelId` | Also for an `act` grant. A chat whose CLI isn't running starts on that model. |
| `folders.list` | | Result: `folders: [{windowId, path}]`. |
| `folder.add` | `path` | An absolute path to an existing folder; it's added to `config.json`. Result: `folders`. `gone.folder` otherwise. |
| `account.refresh` | `provider` | Result `message`: "Signed in as …" / "… isn't signed in.". |
| `account.signIn` | `provider, method?` | Result `message`: the page to open (and `code …` for a device code), space-separated. When the sign-in ends: `result {id: "<id>:done", ok, message}`. |
| `account.submit` | `provider, serial, input` | The code from the page. |
| `account.cancel`, `account.signOut` | `provider` | |

| `auth.gh` | | `gh auth login --web` on the box. Result: `url` and `authCode` (the one-time code to type at `url`; `code` stays the error field). When it ends: `result {id: "<id>:done", ok}`, `gh auth setup-git` run, and a `delta` with `ghSignedIn`. |

All other 1.2/1.3 commands are `invalid` on the box. `account.*` and `auth.gh` need a `full` grant.
Without `method`, `account.signIn` uses the box's no-browser flows: Codex's device code
(`chatgptDeviceCode`: open `url`, type the code) and Claude's page (`claudeai`: open the page,
then send the code it shows with `account.submit`).

## GitHub

`ghSignedIn` (whether `gh auth status` succeeds for github.com) is in `welcome.host` and in the
`snapshot` (beside `windows` and `chats`). It's read on each connect and after `auth.gh`, never polled.

## CLIs

- A chat's CLI starts on its first send and stops after 10 minutes with nothing to do; the next
  send resumes the session. At most 3 run at once: a send past that stops the least recently
  used idle one, else answers `busy`.
