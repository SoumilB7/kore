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

`--scale` adds the UI at scale (below) after the rest, on the same build.

## UI at scale

`scripts/ui-scale.sh [--bin <release bin dir>] [--sizes narrow,laptop,large] [--out <dir>]` works
every area of the window as a person does and times it, at three window sizes and two loads. It
exists because element checks at one size missed what breaks at a large window, in a long chat or
with many tabs, and because clicking a control isn't checking that it worked.

- **Areas** (`Catalogue/ScaleStorylines.swift`, `ScaleGapStorylines.swift`, tag `scale`), at the
  **light load** each area's own storyline with its checks (the effect, not just the click):
  - tabs (select, ⇧-select, ⌘W, ⇧⌘T, drafts back where they were);
  - groups: made, folded, a tab dragged out, closed with a chat working, new tabs placed after;
  - the model and mode pickers;
  - Devices (the KoreNet switch, a phone allowed and denied) and its one + (Add a box, Add a phone);
  - the agent map (and a tab's click giving the chat back), History (search, open at the
    message, the current row);
  - the explorer (copy, paste, rename with undo, trash, Open in Terminal);
  - table and code copy (the pasteboard holds exactly the text);
  - the rail (a mark's click lands on its message);
  - the composer (sends, answered by the scripted CLI);
  - the terminal (a shell echoes), and a command's whole output (1,500 lines opened mid-run, the
    lines after appended, "No output yet" for a quiet one; Claude's file, Codex's stream);
  - Arsenal (its tint) and Arsenal's tab groups;
  - Kore's questions (rename, trash, unsaved edits, a move, quit, a terminal's close) and tip;
  - a box window's History (listed by the box, a pick opened there and shown as a tab).
- **Heavy loads**:
  - 30 tabs: tabs, a group's popup (named, recoloured, a new tab in it, ungrouped), Devices, the
    terminal, the agent map, History, both pickers, Arsenal;
  - a chat of 300 turns: open, scroll, rail, both copies, both pickers at their anchors, a
    message sent;
  - 500 files: the explorer expands, renames, trashes.
- **Sizes**: narrow 560×700, laptop 1440×860, large 3008×1692 (`--size` per app).
- **Timing**: each click or key is timed from the action to the first frame that two more follow
  at the display's pace (the main thread free and drawing again), against 100 ms; its own
  main-thread work (`busy`) and the longest frame gap on the way (`worst`) are logged beside it.
  A scroll's frames are timed at p95 against 16 ms. Over budget is a ✘ but doesn't stop the area:
  its later steps are still timed.
- **Layout**: popups whole in the window and at their anchor; each area ends with the live
  check's Look (frames steady, no work word left, nothing clipped) and its edge controls whole.
  Settling counts looks, not milliseconds: a look's cost grows with the window's pixels (a large
  window at 2× is 20 MP, 30 times a narrow one), so every size gets 16 comparisons at least, and
  the frames compared for flicker are never closer than one look takes. Text is read at 1×, with
  time in proportion to its pixels; the report says how many looks were read (an unread look's
  stale and clipped checks didn't run).
- **Load gate**: before each size, the 1-minute load at most the Mac's cores, so a runnable thread
  doesn't queue for one; above it a step's time is the queue's as much as the app's. It waits up
  to `KORE_SCALE_WAIT` seconds (600); a size run over it anyway is marked loaded, and its
  over-budget-only ✘ say so.
- **Pending**: an area whose feature the build doesn't have (a storyline not in it, or the model or
  screen without the feature) is ◌ pending, not ✘: its walk is found by name as the run starts.

Size by size, Claude's and Codex's apps run at once (six apps at once loaded the Mac enough to
time the load, not the app), each off screen under its own name (defaults, pasteboard, Kore
folders), input in process, the scripted CLI. Areas that don't depend on the CLI run in one of
the two. The output is one ✔/✘ per area × load × size × CLI with its slowest step, ◌ per pending
area, the ten slowest steps, the looks read, the gate per size, then the total; the detail is
`<out>/<size>-<cli>/ui-scale.jsonl`, `report.txt` and `shots/`, under `$TMPDIR/kore-ui-scale`.
Not covered: a live model's turns, the phone, real pointer hover and window-server input
(storylines press in process; hover-only effects aren't seen), and other Macs' displays.