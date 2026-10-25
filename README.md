<p align="center"><img src="Resources/kore-transition.svg" width="128" alt="Kore"></p>
<h1 align="center">Kore</h1>
<p align="center"><b>What VS Code could have been.</b></p>
<p align="center">A native macOS app for the Claude Code and Codex CLIs.</p>

Kore runs the `claude` and `codex` CLIs on your Mac and gives them a proper interface: a window
per folder, tabs for chats, files, terminals and history. The CLIs do the work; Kore shows it.

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
