#!/bin/zsh
# scripts/devrun: a job runs as its own to macOS (a launchd job: its own resource coalition, the
# one Battery and Activity Monitor charge, and its own responsible process), while its stdout,
# stderr, exit code, folder, environment and signals stay the caller's. Outside a Kore, and inside
# a job, it runs the command in place. Prints the evidence (`--who`: responsible pid, coalition).
cd "${0:A:h}/../.."
zmodload zsh/datetime
fails=0
check() { if eval "$2"; then print "✔ $1"; else print "✘ $1"; fails=$((fails + 1)); fi }
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
dr=$PWD/scripts/devrun
start=$EPOCHREALTIME

here=$($dr --who)
print "  caller: $here"
mine=${${here#*coalition }%% *}

# KORE_DEVRUN=always: the job route even when this test runs outside a Kore.
export DR=$dr
inside=$(cd $tmp && KORE_DEVRUN=always FOO='a b&<c>' $dr --name devrun-test -- /bin/zsh -c '
  print -r -- "who $("$DR" --who)"
  print -r -- "pwd $(pwd -P)"; print -r -- "foo $FOO"; print -r -- "job $KORE_DEVRUN_JOB"
  print -u2 "to stderr"; exit 7' 2>$tmp/err); code=$?
who=${${(M)${(@f)inside}:#who *}#who }
print "  job:    $who"
pid=${${who#pid }%% *}
resp=${${who#*responsible }%% *}
coal=${${who#*coalition }%% *}
check "the job is its own responsible process (responsible $resp = its launcher, not the caller's)" \
  '[[ -n $resp && $resp != ${${here#*responsible }%% *} ]] && (( resp > 1 ))'
check "  in a resource coalition of its own (not the caller's $mine)" '[[ -n $coal && $coal != 0 && $coal != $mine ]]'
check "  no Kore owns it" '[[ $who == *" kore 0" ]]'
check "  stdout, stderr and the exit code are the caller's" \
  '(( code == 7 )) && [[ $(<$tmp/err) == "to stderr" ]]'
check "  the caller's folder and environment" \
  '[[ $inside == *"pwd ${tmp:A}"* && $inside == *"foo a b&<c>"* && $inside == *"job devrun-test"* ]]'
check "  nothing left in launchd" '! launchctl list | grep -q "dev.kore.devrun.devrun-test"'

merged=$(KORE_DEVRUN=always $dr --name devrun-test -- /bin/zsh -c 'print 1; print -u2 2; print 3; print -u2 4' 2>&1)
check "2>&1 keeps the order" '[[ $merged == $'"'"'1\n2\n3\n4'"'"' ]]'

KORE_DEVRUN=always $dr --name devrun-test -- /bin/sleep 30 & caller=$!
for _ in {1..50}; do pgrep -f '^/bin/sleep 30$' >/dev/null && break; sleep 0.1; done
kill -INT $caller; wait $caller; code=$?
check "an interrupt ends the job and says so (130)" '(( code == 130 )) && ! pgrep -f "^/bin/sleep 30$" >/dev/null'

# In place: outside a Kore (KORE_DEVRUN=off stands for that here) and inside a job.
off=$(KORE_DEVRUN=off $dr --name devrun-test -- $dr --who)
check "outside a Kore it runs in place (the caller's coalition)" '[[ ${${off#*coalition }%% *} == $mine ]]'
nested=$(KORE_DEVRUN=always $dr --name outer -- /bin/zsh -c '"$DR" --who; KORE_DEVRUN= "$DR" --name inner -- "$DR" --who')
check "a job inside a job stays in its coalition" \
  '[[ ${${${(f)nested}[1]#*coalition }%% *} == ${${${(f)nested}[2]#*coalition }%% *} ]]'

# The named hold instead of caffeinate's.
/bin/sleep 3 & holder=$!
$dr --hold devrun-test $holder &!
for _ in {1..30}; do pmset -g assertions | grep -q '"Kore Dev: devrun-test"' && break; sleep 0.1; done
check "--hold keeps the Mac out of idle sleep as \"Kore Dev: devrun-test\"" \
  'pmset -g assertions | grep -q "PreventUserIdleSystemSleep named: \"Kore Dev: devrun-test\""'
wait $holder; sleep 0.3
check "  and lets go when its holder ends" '! pmset -g assertions | grep -q "Kore Dev: devrun-test"'

printf "devrun: %d failed (%.1fs)\n" $fails $(( EPOCHREALTIME - start ))
(( fails == 0 ))
