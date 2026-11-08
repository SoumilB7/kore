# kore-host: Kore's chats on a Linux box

kore-host runs Kore's chats on another machine, a "box": a Linux server, a workstation or a
cloud VM that you reach with `ssh`. A Kore window on your Mac shows a box folder's chats, while
the claude and codex CLIs run on the box, in its files. The Mac talks to it over your own SSH:
`ssh <box> ~/.local/bin/kore-host attach --as <grant>`. Nothing on the box listens on the
network, and nothing runs there while it's idle except one small daemon waiting on a Unix socket.

The protocol is in [link-1.4-box.md](link-1.4-box.md).

## What a box needs

- Linux on x86_64 or arm64 (aarch64). kore-host is a static binary, so any distribution works.
- systemd with user services. Without systemd, run `kore-host run` from your own init system.
- An SSH login from the Mac with a key (Kore's ssh never asks for a password), and the host key
  accepted once (`ssh <box>` in Terminal).
- The CLIs you want there: claude (its native installer puts it in `~/.local/bin`) and codex
  (`npm i -g @openai/codex`, which needs `nodejs` and `npm`), and `git`.
- `rsync`, for two-way sync (the Mac runs its own `/usr/bin/rsync`, which needs one on the box).
  Minimal images often leave it out: `sudo apt install rsync` on Debian and Ubuntu.

## Setting it up from Kore

1. In the left panel, switch to Boxes and choose **Add a box…**. Pick the host from your SSH
   config.
2. Open its row. If the row says "kore-host isn't on <box> · Set up", click **Set up**. Kore then:
   - asks the box for its CPU (`uname -sm`);
   - copies its kore-host to `~/.local/bin/kore-host` (beside it as `kore-host.new`, then moved
     over, so a running copy isn't disturbed);
   - runs `kore-host install-service`;
   - runs `kore-host allow <this Mac's name> --control full`;
   - connects.
3. Choose **Add folder…** and give a folder on the box, such as `~/Code/project`.

When the line says something else, its action fixes that case:

| Line | Action |
|---|---|
| Can't reach <box> | none: ssh itself failed, so try `ssh <box>` in Terminal |
| kore-host isn't on <box> | Set up |
| kore-host is stopped on <box> | Start (`systemctl --user start kore-host`) |
| <box> doesn't know this Mac | Set up (grants this Mac again) |
| <box> runs an older kore-host | Update (copies this Kore's kore-host and restarts the service) |

An update restarts the service, which ends any turn that is running on the box.

To remove a box, right-click its row and choose **Remove**. Kore forgets the box on this Mac and
changes nothing on the box.

## Setting it up by hand

A Kore built with `KORE_BUNDLE_BOX_HOST=1` carries the binaries as
`Contents/Resources/kore-host-linux-x86_64.xz` and `kore-host-linux-aarch64.xz`; any other build
downloads its version's from the GitHub release (`kore-host-linux-<arch>.xz`) and uses it only if
its SHA-256 matches the one the build recorded.

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

`install-service` does four things:
- writes `~/.config/systemd/user/kore-host.service` with the binary's real path, and with a
  PATH that includes `~/.local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `/usr/local/bin` and
  `/usr/bin`;
- turns on linger (`loginctl enable-linger`), so the service keeps running after you log out.
  If it can't, it prints the `sudo` command that does;
- enables the service;
- (re)starts it.

Run it again after replacing the binary.

## Two-way sync

A folder on the Mac can get a copy on a box, so its chats run there on the same files. From the
folder's window, the box button's popup offers to open it on a box. Kore then:
- makes the copy at `~/Code/<name>` on the box: a `git clone` of the folder's origin at its branch
  and commit, or an empty folder (`git init` for a repository without an origin);
- asks once before carrying more than 1 GB or 20,000 files, and refuses when the box hasn't the
  room;
- adds the copy to the box's folders and opens its window.

While that window is open, Kore keeps both sides the same with rsync over your SSH login. The Mac
watches its side with FSEvents; kore-host watches the box's with inotify and only says what
changed. Nothing polls, and nothing syncs while the window is closed: the next open catches up.
- Both ends leave out `.git/`, `.build/`, `node_modules/`, `.DS_Store` and what each folder's
  `.gitignore` names. Only regular files are carried.
- Edits, new files and deletes go both ways: a file deleted on one side is deleted on the other.
- A file changed on both sides since the last sync is kept twice: the Mac's in place, and the
  box's beside it as `<name> (<box>).<ext>`. The window's box button marks it.
- When a sync can't run (the box is offline, or rsync is missing), the window's box button says
  "Sync paused", and the next change tries again.

The Mac keeps the pairs in Kore's settings, and what both sides last agreed on (each file's size
and mtime) in `~/Library/Application Support/Kore/hosts/<box>/sync/`.

## Commands

| Command | |
|---|---|
| `kore-host status` | Shows the version, whether the daemon runs, the service and linger, grants, folders (missing ones marked), and where claude and codex were found. |
| `kore-host allow <name> [--control watch\|act\|full]` | Grants a client. `allow` again issues a new secret. |
| `kore-host revoke <name>` | Removes a grant. Its connection ends at its next command. |
| `kore-host grants` | Lists the grants and their control. |
| `kore-host run` | Runs the daemon (what the service runs). A second one exits and leaves the first alone. |
| `kore-host install-service` | Installs, enables and (re)starts the user service. |
| `kore-host uninstall [--purge]` | Stops, disables and removes the service. `--purge` also removes the state, grants and config. |
| `kore-host --version` | Prints the version and the link version. |

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
| `$XDG_RUNTIME_DIR/kore-host/` | `link.sock`, `run.lock` and `kore-host.pid` (`/run/user/<uid>` without `XDG_RUNTIME_DIR`) |
| `~/.config/systemd/user/kore-host.service` | the service |

How the box handles its files:
- `XDG_CONFIG_HOME` and `XDG_STATE_HOME` move these, as usual.
- Paths in `config.json` must be absolute or start with `~`.
- If `config.json` can't be read, it's kept as it is, the journal says why, and nothing saves
  over it. Fix it, then restart the service.
- A folder that's gone stays listed as missing.
- kore-host's own log lines go to the journal: `journalctl --user -u kore-host`. They cover
  start, stop, connections, refusals, CLI starts and stops, and failed writes. They never hold
  a secret or anything said in a chat.

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
