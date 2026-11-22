# Dev builds and Kore's battery

## Dev jobs run as their own

macOS charges energy (Battery settings, Activity Monitor's Energy tab) by **resource coalition**:
an app's coalition holds every process it starts and everything under them. Kore already
disclaims *responsibility* for the CLIs it starts (`Disclaim`), yet a build started by a chat's
agent (Kore → claude → zsh → one-build.sh → swift…) stayed in Kore's coalition and was charged to
Kore. An unprivileged process can't make a coalition (`coalition_create` gives EPERM); only launchd
starts a process in a new one.

`scripts/devrun` (a zsh wrapper that compiles `scripts/devrun.c` once into
`~/Library/Caches/KoreDev/devrun/<cksum>/kore-devrun`) runs a command as a launchd job of its own
in the user's GUI domain: a plist in a scratch folder under `$TMPDIR` (nothing in
`~/Library/LaunchAgents`), `ProcessType` Interactive (the priority Kore's or a terminal's children
get), booted out when the job ends. The caller keeps the command's stdout and stderr (FIFOs, one
for both when they're the same file, so `2>&1` keeps its order), its exit code (128+signal when
signalled), folder, environment and open-file limit; stdin is `/dev/null`. The caller's INT, TERM
and HUP go to the job's process group. A caller that's killed leaves nothing behind: the job's
output has no reader, and its launcher boots itself out.

Outside a Kore (no ancestor `Kore*.app` sharing the caller's coalition: Terminal, a job already)
it runs the command in place. `KORE_DEVRUN=always` routes any caller, `KORE_DEVRUN=off` none. The
job sees `KORE_DEVRUN_JOB=<name>`, which the scripts check so they route once.

These route themselves: `scripts/one-build.sh`, `scripts/verify-fast.sh`, `scripts/storylines.sh`
(not with `--real-input`/`--real-keys`: posting events uses the caller's permission),
`android/scripts/check.sh`, `scripts/release.sh --prepare`.

`devrun --hold NAME PID` replaces `caffeinate -i -w PID`: the same idle-sleep hold, named
`Kore Dev: NAME` in `pmset -g assertions`. one-build.sh (while a slot is held) and verify-fast.sh
keep it: an idle sleep froze a check mid-run. The storyline and bench activities are named
`Kore Dev: …` too.

Checking it: `scripts/devrun --who [pid]` prints a process's responsible pid, resource coalition
and the Kore it is charged to (0: none); `scripts/tests/devrun.sh` checks the whole route.

## Kore Dev

`scripts/build-app.sh --dev [--install]` builds `build/Kore Dev.app`: bundle id
`dev.kore.KoreDev`, binary and name "Kore Dev", an amber icon; `--install` puts it in
`~/Applications`. It never shares the owner's Kore's settings or folders: its defaults domain is
`dev.kore.KoreDev`, and `KoreFolders` gives it `~/Library/{Application Support,Logs,Caches}/Kore Dev`,
so its agent socket, link sockets, KoreNet identity (`secrets`), phone-app copy and logs are its
own. The `kore` command inside it talks to Kore Dev's socket. It never checks for updates (an
update would replace the owner's Kore). The `Kore` binary run as built (`swift run Kore`,
`.build/release/Kore`) is Kore Dev too; renamed binaries (KoreBench, KoreLaunch, kore-storylines-N)
keep `Kore-<name>` as before. Releases (`install.sh`, `release.sh`, plain `build-app.sh`) stay
Kore (`dev.kore.Kore`), the only one that keeps `~/Library/Application Support/Kore`.

## Live check

`scripts/live-check.sh [--bin <release bin dir>] [--tests <test scratch> | --no-relay] [--devices [--switch]]` checks Kore as a person
would, on top of the gate: real frames of the windows, read automatically. The gate's fakes and
element checks miss what only shows on screen (a flickering popup, a rail stretched to the window,
a stale card, groups gone after a window reopens).

- **tour** (budget 3 min): the `livecheck` storylines (`Catalogue/LiveCheckStorylines.swift`), one
  per area. Each walks the area's own storyline, then looks at it: once its frames settle, three
  frames 300 ms apart must neither keep changing nor change back (flicker; overlay scrollers,
  which flash and fade on their own, are left out of every comparison), the text read off the frame (Vision) holds no work word left over ("Installing…")
  and no clipped label ("This Ma"), the message rail measures the same at two heights, nothing
  covers text, controls at the edges are whole in narrow and wide windows, and clicks settle under
  `KORE_LIVE_SETTLE_MS` (800 ms). Claude and Codex run side by side, each in one off-screen
  kore-storylines app with input in process; areas that don't depend on the CLI run in one of them.
- **net** (budget 2 min, beside the tour): KoreNet, boxes, the tailnet switch, the link and remote
  control on their fakes, and the phone relay and KoreNet system tests (Mac, kore-host and an
  emulated phone on an in-memory tailnet). Those run from `--tests` (the gate's test build), else
  this tree's `.build-test`, built once if missing: SwiftPM links every test target into one
  bundle, so there's no smaller build of them. `--no-relay` leaves them out.
- **--devices**: mybox over `ssh mybox`: kore-host's version and daemon, the link over SSH and over
  the tailnet, and whether the Mac and the box say the same tailnet. **--switch** (about 6 min,
  never by default) stops tailscaled on the box after arming two root restore timers (300 s, 600 s)
  and reads the box's journal for the move to Kore's tailnet and back.

The output is one ✔/✘ per area, a ✘ with a short reason and the frame that shows it (relative to
the run's folder), a part over its budget as `✘ <part>: slow`, and the total with each part's time.
Detail (every read text, settle time and size) goes to `<out>/live-check.log` and
`<out>/<shard>/live-notes.txt`; the run's folder is under `$TMPDIR/kore-live-check`. Without
`--bin` it builds once in release first; the gate passes its own build.
