# Kore

A native macOS app for the Claude Code and Codex CLIs.

Kore runs the `claude` and `codex` CLIs you already have installed and logged in, and gives them
a simple interface: one window per folder, tabs for chats, and history for past sessions.

## Requirements

- macOS 15 or later
- Swift 6.2 or later toolchain (Xcode Command Line Tools)
- `claude` and/or `codex` installed and logged in

## Build

```sh
./scripts/build-app.sh            # builds build/Kore.app
./scripts/build-app.sh --install  # also copies it to /Applications and links `kore`
```

## Command line

```sh
kore           # opens the current folder in Kore
kore ~/code/x  # opens that folder
```

A folder that is already open has its window brought to the front instead.
