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
