# Contributing

## Setup

- macOS 15 or later, Xcode Command Line Tools with Swift 6.2 or later (no Xcode needed)
- the `claude` and/or `codex` CLI, for anything that talks to a real CLI

```sh
swift build                       # debug build of everything
swift run Kore                    # run the app from the package
./scripts/build-app.sh            # release build/Kore.app
```

## Tests

Unit tests use Swift Testing. With only the Command Line Tools, point the compiler at its plugin:

```sh
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

End-to-end flows ("storylines") drive the real app against a scripted CLI, so they need no
account and spend nothing:

```sh
./scripts/storylines.sh --list
./scripts/storylines.sh --tag chat
```

`./scripts/readme-shots.sh` retakes the README's screenshots the same way (demo folders, emails
masked) and frames them into `docs/images` (needs Pillow).

`--cli process` plays recorded CLI sessions from `Tests/Fixtures/cassettes` instead. Before
committing a new recording, strip anything account-specific from it.

## Conventions

- **The CLI is the source of truth.** Kore doesn't reimplement what a CLI already does. When a
  CLI or its editor extension has already decided a name, label or behaviour, Kore follows it.
- **Both CLIs.** A feature lands for Claude and Codex together, and a chat only ever shows its
  own CLI's modes, models and commands.
- **Theme tokens, not numbers.** Views take colours, sizes and spacing from `Shared/Theme` and
  `Shared/Kit`; `scripts/lint-theme.sh` fails on raw values.
- **Cost follows what's on screen.** Layout follows the window size, work is lazy and windowed,
  and nothing runs while hidden. It has to hold up from one chat to dozens and from a small folder
  to a huge one.
- **No warnings.** Debug and release builds stay warning-free.

## Releases

1. Bump `VERSION` and add a section to `CHANGELOG.md`.
2. `./scripts/make-dmg.sh` builds `build/Kore-<version>.dmg` and its checksum.
3. `./scripts/release.sh` tags `v<version>` and publishes the DMG as a GitHub release.
