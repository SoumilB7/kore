# kore-host: Kore's chats on a box

kore-host runs Kore's chats on another machine, a "box": a Linux server, a workstation, a cloud
VM, a container or another Mac, anything you reach with `ssh`. A Kore window on your Mac shows a box folder's chats, while
the claude and codex CLIs run on the box, in its files. The Mac talks to it over your own SSH:
`ssh <box> ~/.local/bin/kore-host attach --as <grant>`. Nothing on the box listens on the
network, and nothing runs there while it's idle except one small daemon waiting on its Unix sockets.

The protocol is in [link-1.4-box.md](link-1.4-box.md).

## What a box needs

Only an SSH login from the Mac with a key (Kore's ssh never asks for a password). Kore finds the
rest itself and says what's missing.

| Machine | kore-host | Kept running by |
|---|---|---|
| Linux on x86_64 or arm64 (aarch64), any distribution | a static binary | a systemd user service, with linger |
| Linux without a systemd user session (containers, WSL, some VPSes) | the same | nothing: started on demand (below) |
| macOS 15 or later on arm64 or x86_64 | a macOS build | a LaunchAgent |

- **Started on demand.** Where there's no service manager, `kore-host attach` starts `kore-host
  run` itself (under `nohup`, in its own session) when no daemon answers, and it keeps running
  after. Its socket, pid and lock are in `~/.local/state/kore-host/run/`, its lines in
  `~/.local/state/kore-host/kore-host.log`. It behaves the same as the service, except that
  after the machine restarts it starts at the next connect.
- **Tools.** `rsync` for two-way sync and `git` for the CLIs. When one is missing, the box's line
  says so in one line ("rsync isn't on mybox · sync needs it") with the command that adds it:
  Kore runs it itself only where it needs no password (Homebrew on a Mac), and otherwise copies it
  for you to run (`sudo apt-get install -y rsync`, `sudo dnf …`, `sudo apk add …`).
- **The CLIs.** Set up agents installs them (below).

## Setting it up from Kore

1. In a new window (⌘N), the switcher at the top reads **This Mac | <boxes> | +**; click **+**
   (Add a box…). A window is either a folder on this Mac or a folder on a box, chosen when it
   opens. Type a host from your SSH config
   (it's suggested as you type), or any destination as `user@host` or `user@host:port`. A typed
   destination is kept in Kore's own list, never written into `~/.ssh/config`. Only letters,
   digits, `.`, `_` and `-` make a name, and none starts with `-`; ssh gets the host as one word
   after `--`, and the user and port as options.
2. Kore checks the machine over one ssh session that only reads (`uname`, `/etc/os-release`,
   `command -v` for the tools it uses, the CLIs' `--version`, `$SHELL`, `$HOME`, free room, the git
   identity). It keeps what it found for that box. It checks again only on Set up, Update, Set up
   agents or Check again.
3. The new window now stands on the box: its name as the title, and under it "Not set up on
   <box> · Set up". **Set up** runs, a line at a time:
   - **Checking** the machine, and stopping with one line if Kore can't run there (another CPU,
     macOS before 15, under 150 MB free);
   - **Getting** the right kore-host (Linux x86_64 or aarch64, or macOS) from the app, the
     `koreHostBinary` setting, or this version's GitHub release, checked against the SHA-256 the
     build recorded;
   - **Copying** it to `~/.local/bin/kore-host.new`, running its `--version` there, and only then
     moving it over the old one (a running copy isn't disturbed, and one that can't run there
     never replaces one that can);
   - **Starting** it: `kore-host install-service` picks systemd, launchd or on demand;
   - **Letting this Mac in**: `kore-host allow <this Mac's name> --control full`;
   - **Connecting**.
4. Choose **Open Folder…**: a browser of the box's folders opens at its home. ↑ ↓ light a
   folder, Return goes into it, ⌫ or ← go up, ⌘⇧. shows dotfiles, and a path typed or pasted in
   its field goes there (`~` is the box's home). **New Folder** makes one; **Open** adds the lit
   folder (else the one shown, else the path typed) to what the box serves and opens its window.

The new window switches between this Mac and a box with the switcher, or with the box button in
its title row (it toggles between This Mac and the last box shown). On a box, the list under
Open Folder… holds the box's folders and the chats open in them; a chat's row opens its folder's
window with that chat in front.

Each failure is one line with the one action that fixes it:

| Line | Action |
|---|---|
| Can't reach <box> | Try again |
| Can't find <box> · check the name | Try again |
| <box> needs a key · ssh-copy-id <box> | Copy (run it in Terminal) |
| <box>'s host key is new · ssh <box> once in Terminal | Copy |
| <box>'s host key changed · check it, then ssh-keygen -R <host> | Copy |
| Not set up on <box> | Set up |
| Stopped on <box> | Start (`kore-host start`) |
| <box> doesn't know this Mac | Set up (grants this Mac again) |
| <box> needs an update | Update (copies this Kore's kore-host and restarts it) |
| rsync isn't on <box> · sync needs it | Copy, or Install where no password is needed |
| No agents on <box> yet | Set up agents |
| N differences from this Mac | Fix |

These lines show under the box's name in the new window, one at a time, only when there's
something to do; with nothing else to say, a GitHub line shows while `gh` isn't signed in there.

An update restarts the daemon, which ends any turn that is running on the box; Kore asks first
when a chat there is working. Nothing dials until the new window stands on a box (or a box
window opens), and nothing polls.

To remove a box, right-click it in the switcher and choose **Remove**. Kore forgets the box on this Mac and
changes nothing on the box.

## Set up agents

**Set up agents** (the box's line in the new window, or its right-click menu in the switcher) opens one popup with a line per
agent:
- **claude**: installed with its own installer (`curl -fsSL https://claude.ai/install.sh`, into
  `~/.local/bin`);
- **codex**: its npm package under `~/.npm-global` when `npm` is there, else its standalone
  binary from its GitHub release into `~/.local/bin`;
- **gh**: its release binary into `~/.local/bin`.

All of them go under your home without sudo, where the box's service looks (its PATH has
`~/.local/bin` and `~/.npm-global/bin`). An installer that needs a tool the box lacks says which,
with the command that adds it. Once installed, each line signs in on the box through its
no-browser flow: the page opens in this Mac's browser, the code has Copy, and claude takes the
code back in a field. The login stays on the box. Kore never copies this Mac's logins, keys or
settings to a box.

In a box chat, the Account popup is the same as a local chat's, with the box's login for that
chat's CLI: its sign-in (no browser on the box, no key), sign-out and the account it shows are
the box's. A box keeps one login per CLI.

## A box window

A box window's left panel is the box folder's files, as Kore's Files explorer shows a Mac
folder's, read over the link: folders open and close, and a file opens read-only in a file tab
(text up to 2 MB, the first 2 MB of a larger one; images). Nothing is created, renamed or deleted
from there. Reload lists the open folders again; so does a turn's end in that window, and the
link coming back, so the agent's edits show. The box watches nothing for it.

When the link drops for more than 2 seconds, one card over the window says
"<box> disconnected · last update 14:32", with Reconnecting… and **Try again**, or the action
that fixes it (Start, Set up, Update). The chats stay readable under it, and a message typed
meanwhile waits: "Sends when <box> is back". The card goes once the link is back.

Under the agents, the popup lists what else differs from this Mac, so box chats behave the same:
- each CLI's presence and version (claude, codex, gh, git, node, rsync), when the major or minor
  version differs, with **Update** for the agents;
- each CLI's login: not signed in, or signed in as someone else;
- the git identity, with **Use mine** (`git config --global user.name` and `user.email` there);
- claude's user MCP servers, skills, plugins and agents, and codex's MCP servers, by name, and
  each CLI's default model. These are listed only, never copied: a server's entry can carry a
  secret. `kore-host facts` reads them on the box, names only.

The compare is kept with the box and runs again only on Set up, Update, Set up agents or **Check
again**.

## Setting it up by hand

A Kore built with `KORE_BUNDLE_BOX_HOST=1` carries the binaries as
`Contents/Resources/kore-host-linux-x86_64.xz`, `kore-host-linux-aarch64.xz`,
`kore-host-macos-arm64.xz` and `kore-host-macos-x86_64.xz`; any other build downloads its
version's from the GitHub release (`kore-host-<platform>.xz`) and uses it only if its SHA-256
matches the one the build recorded. A development build of Kore uses the `kore-host` built beside
it for a Mac box like the Mac it runs on, and `defaults write dev.kore.Kore koreHostBinary <path>`
names a file, or a folder holding `kore-host-<platform>[.xz]`.

```sh
# On the Mac
curl -LO https://github.com/SoumilB7/kore/releases/download/v<version>/kore-host-linux-x86_64.xz
xz -dc kore-host-linux-x86_64.xz > kore-host
ssh box mkdir -p .local/bin
scp kore-host box:.local/bin/kore-host.new
ssh box 'chmod 755 .local/bin/kore-host.new && mv -f .local/bin/kore-host.new .local/bin/kore-host'

# On the box
~/.local/bin/kore-host install-service
~/.local/bin/kore-host allow <this Mac's name> --control full
~/.local/bin/kore-host status
```

On the Mac, `scutil --get LocalHostName` prints the name Kore uses for its grant. If you want a
different name, set it with `defaults write dev.kore.Kore boxGrant.<box> <name>`.

`install-service` picks how kore-host keeps running: launchd on a Mac, systemd where a user
manager answers (`systemctl --user`), and otherwise on demand. `KORE_HOST_SERVICE=systemd`,
`launchd` or `on-demand` picks one by hand. On a Mac it writes
`~/Library/LaunchAgents/dev.kore.kore-host.plist` (`KeepAlive` on failure, the CLIs' folders and
Homebrew's on PATH) and loads it into the desktop session, or the user's own when you're only
logged in over ssh; if launchd refuses, it falls back to on demand. On demand, it remembers that
in `~/.local/state/kore-host/service` and starts the daemon now.

With systemd, `install-service` does four things:
- writes `~/.config/systemd/user/kore-host.service` with the binary's real path, and with a
  PATH that includes `~/.local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `/usr/local/bin` and
  `/usr/bin`;
- turns on linger (`loginctl enable-linger`), so the service keeps running after you log out.
  If it can't, it prints the `sudo` command that does;
- enables the service;
- (re)starts it.

Run it again after replacing the binary.

## Two-way sync

A box folder lives on the box, and its chats work on the box's files. To also have those files on
the Mac, pair the box folder with a Mac folder: click the Sync button in the box window's title
row (beside the panel button) and pick or make a folder in the open panel. Kore then:
- refuses a Mac folder that already syncs, or sits inside or around one that does, and a box
  folder inside or around a synced one (its Sync button says "Inside <folder>, synced"), naming
  the pair in the way;
- looks at both folders. When the box folder is empty, the Mac's files go to the box; when the
  Mac folder is empty, the box's files come to the Mac. When both have files it asks once, "Both
  have files · Merge (keeps both on conflicts)": a file on one side only goes to the other, and a
  file on both that differs is kept twice (see below);
- asks once before carrying more than 1 GB or 20,000 files, and refuses when the other side hasn't
  the room;
- keeps the pair (the box, the box folder and the Mac folder) in Kore's settings. The Sync
  button's popup then says "Synced locally to ~/Desktop/app", and the window's folder name shows
  the same on hover.

While the box folder's window is open, Kore keeps both sides the same with rsync over your SSH
login. The Mac watches its side with FSEvents; kore-host watches the box's with inotify and only
says what changed. Nothing polls, and nothing syncs while the window is closed: the next open
catches up. The Sync button's dot is accent while in sync, pulses while files move, and is grey
while the sync is paused.
- Both ends leave out `.git/`, `.build/`, `node_modules/`, `.DS_Store` and what each folder's
  `.gitignore` names. Only regular files are carried.
- Edits, new files and deletes go both ways: a file deleted on one side is deleted on the other.
- A file changed on both sides since the last sync is kept twice: the Mac's in place, and the
  box's beside it as `<name> (<box>).<ext>`. The Sync button's popup says so.
- A side that is missing or empty, or a round that would delete more than half of what was agreed
  (10 files or more), pauses the sync; the Sync button's popup asks before such a delete.
- When a sync can't run (the box is offline, or rsync is missing), the Sync button's popup says
  "Sync paused", and the next change tries again.

To stop, click the Sync button and choose **Stop syncing**; **Open <folder>** shows the Mac
folder in Finder. It ends the sync and forgets the pair;
no file is deleted on either side.

What both sides last agreed on (each file's size and mtime) is kept in
`~/Library/Application Support/Kore/hosts/<box>/sync/`, and goes with the pair.

## Commands

| Command | |
|---|---|
| `kore-host status` | Shows the version, whether the daemon runs, the service and linger, grants, folders (missing ones marked), and where claude and codex were found. |
| `kore-host allow <name> [--control watch\|act\|full]` | Grants a client. `allow` again issues a new secret. |
| `kore-host revoke <name>` | Removes a grant. Its connection ends at its next command. |
| `kore-host grants` | Lists the grants and their control. |
| `kore-host run` | Runs the daemon (what the service runs). A second one exits and leaves the first alone. |
| `kore-host install-service` | Installs and (re)starts it: the systemd user service, the LaunchAgent, or on demand. |
| `kore-host start` | Starts the daemon as it was installed. |
| `kore-host facts` | Prints the CLIs' MCP servers, skills, plugins, agents and default models, by name only, as JSON. |
| `kore-host uninstall [--purge]` | Stops and removes the service, the LaunchAgent or the on-demand daemon. `--purge` also removes the state, grants and config. |
| `kore-host --version` | Prints the version and the link version. |
| `kore-host mcp` | The `kore_app` MCP server a chat's CLI starts with while its Arsenal is on. kore-host runs it; it isn't run by hand. |

The control levels:
- `watch` reads only.
- `act` also sends, stops, answers, sets the mode, plan and model, makes chats and adds folders.
- `full` also gets the model pickers and context, may raise a chat's mode, and signs the box's
  CLIs and `gh` in.

## Files

| Path | |
|---|---|
| `~/.local/bin/kore-host` | the binary |
| `~/.config/kore-host/config.json` | `{"folders": ["/home/you/Code", "~/other"]}` (0600) |
| `~/.local/state/kore-host/grants/<name>.json` | one per grant, with its secret (0600) |
| `~/.local/state/kore-host/chats/<id>/` | each chat's record and log |
| `~/.local/state/kore-host/models.json` | each CLI's models, as it last listed them |
| `$XDG_RUNTIME_DIR/kore-host/` | `link.sock`, `agent.sock`, `run.lock` and `kore-host.pid` (`/run/user/<uid>` without `XDG_RUNTIME_DIR`) |
| `~/.config/systemd/user/kore-host.service` | the systemd service |
| `~/Library/LaunchAgents/dev.kore.kore-host.plist` | the LaunchAgent, on a Mac |
| `~/.local/state/kore-host/service` | `launchd` or `on-demand`, when kore-host isn't a systemd service |
| `~/.local/state/kore-host/kore-host.log` | the on-demand daemon's and the LaunchAgent's lines |

On a Mac box, the state and the socket live in `~/Library/Application Support/kore-host/` unless
the XDG variables are set. On demand, the socket, pid and lock are in
`~/.local/state/kore-host/run/`.

How the box handles its files:
- `XDG_CONFIG_HOME` and `XDG_STATE_HOME` move these, as usual.
- Paths in `config.json` must be absolute or start with `~`.
- If `config.json` can't be read, it's kept as it is, the journal says why, and nothing saves
  over it. Fix it, then restart the service.
- A folder that's gone stays listed as missing.
- kore-host's own log lines go to the journal: `journalctl --user -u kore-host`. They cover
  start, stop, connections, refusals, CLI starts and stops, and failed writes. They never hold
  a secret or anything said in a chat.

## Arsenal

A box chat's agent can use Kore's own tools (new tabs, other chats, this chat's model), as a chat
on the Mac can, once you turn Arsenal on for it: right-click its tab, or ⌥⌘K. The tier and its
limits are the Mac's, and only the Mac decides each call.
- While Arsenal is on, kore-host starts the chat's CLI with `kore-host mcp`, the `kore_app` MCP
  server. Turned on or off, the CLI starts again at its next message.
- Each tool call goes to the daemon on `agent.sock` with the chat's id and a secret the daemon gave
  that CLI alone, then on to the Mac over the link. kore-host decides nothing.
- New chats open on the same box and folder; `place: "mac"` opens one in a window on the Mac.
- With no Mac connected, a call says "Kore isn't connected to <box> right now".

## Uninstalling

```sh
~/.local/bin/kore-host uninstall --purge
rm ~/.local/bin/kore-host
```

Linger stays on: turn it off with `loginctl disable-linger` if nothing else needs it. On the
Mac, remove the box's row.

## Security

- The box opens no port. The Mac reaches it only through your SSH login, as you.
- The socket is yours alone (0600 in a 0700 folder), and the daemon checks the peer's uid.
- A grant's secret never leaves the box. `attach` answers the daemon's challenge with an HMAC of
  it, so a connection proves it holds a grant.
- A grant's control bounds what its client can do. Box chats follow Kore's own rules: `!` shell
  lines, Always allow and API keys stay refused, and only a full grant may raise a chat's mode,
  up to Auto.
- `revoke` (or `allow` again) ends that grant's live connection at its next command.
- Arsenal's tool calls go only to a full grant's connection, and each is checked on the Mac against
  that chat's tier there. `agent.sock` is yours alone, as `link.sock` is, and a call names its chat
  by a secret that only that chat's running CLI has; it never leaves the box.
