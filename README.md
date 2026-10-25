<p align="center"><img src="Resources/kore-transition.svg" width="128" alt="Kore"></p>
<h1 align="center">Kore</h1>
<p align="center"><b>What VS Code could have been.</b></p>
<p align="center">Your agents, out of the terminal and on one team.</p>
<p align="center"><a href="../../releases/latest">Download</a> · <a href="CHANGELOG.md">Changelog</a></p>

<p align="center"><img src="docs/images/board.png" width="100%" alt="A board of four Claude Code and Codex chats in one tab"></p>

Kore runs the `claude` and `codex` CLIs on your Mac and gives them a proper interface: a window
per folder, tabs for chats, files, terminals and history. The CLIs do the work; Kore shows it.

## Features

### Tab groups

A board holds several chats in one tab, like a control panel (above).

### Multiple accounts

Keep a pool of logins and switch by hand, so nothing rotates behind your back.

<p align="center"><img src="docs/images/accounts.png" width="100%" alt="Account popup with three Claude logins, emails masked"></p>

### Intuitive interaction

Auto-compact, Plan mode without permission prompts, Stay awake, and pasted images.

<p align="center"><img src="docs/images/flow.png" width="100%" alt="A chat after an automatic compaction, in Plan mode with a pasted screenshot"></p>

### Port chats

Carry a Claude Code chat on in Codex, or a Codex chat in Claude Code.

<p align="center"><img src="docs/images/port.png" width="100%" alt="A Claude Code chat continued in Codex"></p>

## Install

Download the DMG from [Releases](../../releases/latest) and drag Kore to Applications. On first
launch, allow it under System Settings → Privacy & Security.

Needs an Apple silicon Mac on macOS 15+, and the `claude` and/or `codex` CLI. Kore offers to
install a missing one.

## Build

```sh
./scripts/build-app.sh --install   # build, install to /Applications, link `kore`
./scripts/make-dmg.sh              # build/Kore-<version>.dmg
```

## `kore`

```sh
ln -sf /Applications/Kore.app/Contents/Resources/kore ~/.local/bin/kore   # once, for DMG installs

kore           # open Kore
kore .         # open this folder
kore setup     # install missing CLIs
```

## License

[MIT](LICENSE)
