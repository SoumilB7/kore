#!/bin/zsh
# The Android gate (phase 18 §10), offline, through the pinned Gradle and dependencies:
#   :link's tests and its noAndroid check, the tailnet shim's Go tests, :app's unit tests,
#   an unsigned assembleRelease on the cached tailnet AAR, the APK's size against its budget,
#   16 KB alignment, and the release dex free of relay, uitest and debug-hook strings.
# Prints one line per part (tests with their runtimes) and exits 0 only when every part passed.
set -u
export KORE_ANDROID="${0:A:h:h}"
source "$KORE_ANDROID/scripts/env.sh"
BUDGET_MB=${KORE_APK_BUDGET_MB:-26}
log="${TMPDIR:-/tmp}/kore-android-check.$$"
fail=0
say() { print -r -- "$1" }
bad() { say "✘ $1"; fail=1 }

# Results of one Gradle test task: "N passed, M failed (Xs)", and each suite with its time.
results() {
    python3 -I - "$1" <<'PY'
import glob, sys, xml.etree.ElementTree as ET
t = f = s = 0; secs = 0.0; rows = []
for p in sorted(glob.glob(sys.argv[1] + "/*.xml")):
    r = ET.parse(p).getroot()
    n, ff = int(r.get("tests", 0)), int(r.get("failures", 0)) + int(r.get("errors", 0))
    t += n; f += ff; s += int(r.get("skipped", 0)); secs += float(r.get("time", 0))
    rows.append(f'    {r.get("name").split(".")[-1]} {n} {float(r.get("time", 0)):.3f}s' + (f" ✘{ff}" if ff else ""))
print(f"{t - f - s} passed, {f} failed ({secs:.2f}s)")
print("\n".join(rows))
PY
}

cd "$KORE_ANDROID"
rm -rf link/build/test-results/test app/build/test-results/testDebugUnitTest
start=$SECONDS
if kore_gradle --offline --no-daemon --quiet :link:test :app:testDebugUnitTest >"$log" 2>&1; then :; else bad "gradle tests (see below)"; grep -E 'FAILED|e: |What went wrong' -A3 "$log" | head -20; fi
grep -q "noAndroid: .* no android imports" "$log" && say "✔ :link noAndroid" || bad ":link noAndroid"
out=$(results link/build/test-results/test); say "✔ :link tests: ${out%%$'\n'*}"; print -r -- "${out#*$'\n'}"
[[ "$out" == *" 0 failed"* && "$out" != "0 passed"* ]] || bad ":link tests"
out=$(results app/build/test-results/testDebugUnitTest); say "✔ :app unit tests: ${out%%$'\n'*}"; print -r -- "${out#*$'\n'}"
[[ "$out" == *" 0 failed"* && "$out" != "0 passed"* ]] || bad ":app unit tests"

GO="${KORE_GO:-/opt/homebrew/bin/go}"
if [[ -x "$GO" ]]; then
    t0=$SECONDS
    if (cd tailnet/go && GOFLAGS=-mod=mod GOPROXY=off "$GO" test ./... >"$log.go" 2>&1); then say "✔ tailnet shim go tests ($((SECONDS - t0))s)"; else bad "tailnet shim go tests"; tail -5 "$log.go"; fi
else
    say "· tailnet shim go tests skipped (no go)"
fi

t0=$SECONDS
if kore_gradle --offline --no-daemon --quiet :app:assembleRelease >"$log" 2>&1; then
    say "✔ assembleRelease, unsigned ($((SECONDS - t0))s)"
else
    bad "assembleRelease"; grep -E 'e: |What went wrong|ERROR' -A3 "$log" | head -20
fi
apk=app/build/outputs/apk/release/app-release-unsigned.apk
if [[ -f "$apk" ]]; then
    bytes=$(stat -f %z "$apk")
    so=$(unzip -l "$apk" lib/arm64-v8a/libgojni.so | awk 'NR==4{print $1}')
    mb=$(python3 -c "print(f'{$bytes/1048576:.1f}')")
    if (( bytes <= BUDGET_MB * 1048576 )); then say "✔ apk $mb MB (budget $BUDGET_MB MB; tailnet .so $(( so / 1048576 )) MB, dex+res $(( (bytes - so) / 1024 )) KB)"; else bad "apk $mb MB over its $BUDGET_MB MB budget"; fi
    "$ANDROID_HOME/build-tools/36.0.0/zipalign" -c -P 16 4 "$apk" >/dev/null 2>&1 && say "✔ 16 KB aligned" || bad "not 16 KB aligned"
    dex=$(mktemp -d)
    unzip -q -o "$apk" 'classes*.dex' -d "$dex"
    hits=$(cat "$dex"/classes*.dex | LC_ALL=C grep -a -o -E 'workers\.dev|uitest|relay|Relay[A-Z]|WsRelay|dev/kore/phone/debug' | sort -u | tr '\n' ' ')
    rm -rf "$dex"
    [[ -z "$hits" ]] && say "✔ release dex: no relay, uitest or debug-hook strings" || bad "release dex holds: $hits"
else
    bad "no release apk"
fi
rm -f "$log" "$log.go"
say "android check: $((SECONDS - start))s, $([[ $fail == 0 ]] && print passed || print FAILED)"
exit $fail
