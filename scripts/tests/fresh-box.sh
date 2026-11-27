#!/bin/zsh
# A box set up from the ground up, as if this Mac's Kore had never seen it: back up everything Kore
# and the box keep of each other, wipe it, and put it back exactly.
#
#   scripts/tests/fresh-box.sh --backup  <alias>             → ~/Library/Application Support/KoreDev/fresh-box/<alias>-<date>/
#   scripts/tests/fresh-box.sh --wipe    <alias>             (asks first; prints what goes)
#   scripts/tests/fresh-box.sh --restore <alias> <backup folder>
#   scripts/tests/fresh-box.sh --verify  <alias> [--expect fresh|installed]   (a ✔/✘ checklist; non-zero on any ✘)
#
# --verify, the clean slate before a storyline: on the box, no kore-host binary, unit, process or
# state (`installed`: exactly one, running), no kore-tailnet process or own-node state, tailscaled
# as FRESH_EXPECT_TAILSCALED says (running, stopped, absent; unchecked when unset), sshd running,
# no kore-rig-* timers or units, no iptables rule beyond the policy (root or sudo -n only), every
# process in FRESH_EXPECT_ALIVE still running (e.g. "slack-watch boxpanel.py"); on this Mac, no
# trace of the box in Kore's settings or folder (`fresh`), no test ssh config left
# (FRESH_TEST_SSH_GLOB, default /tmp/kr-*/ssh_config).
#
# This Mac (Kore quit first: it refuses while Kore runs): in Kore's settings, the box's place in
# `boxHosts` and its `boxGrant.`, `boxKoreHost.`, `boxRecents.`, `boxRecentsForgotten.`,
# `boxTabGroups.` keys, its `syncPairs`, its KoreNet entries (`koreNodes`), names
# (`koreNodeNames`) and pause (`koreNetPaused`), by every key it goes by (its alias and its
# KoreNet id); in Kore's folder, `hosts/<key>`, `nodes/<id>`, its rekey journals and its record in
# `net/devices.json`. The box (over `ssh <alias>`): `~/.local/state/kore-host` (Kore's own node
# state with it), `~/.local/bin/kore-host` and `kore-tailnet`, its systemd unit, `~/.config/kore-host`.
# Wipe uninstalls the service, stops the daemon and removes those; the box's `<host>-kore` node
# is named for removal in the admin console (Kore can't delete a node; signing it out only expires it).
# Never touched: chats' working folders, ~/.ssh, ~/.claude, ~/.codex, anything else on the box.
# Restore wipes what's there now, then puts the backup back and starts kore-host as it was.
#
# FRESH_KORE_DOMAIN (dev.kore.Kore), FRESH_KORE_SUPPORT (~/Library/Application Support/Kore),
# FRESH_KORE_PROCESS (Kore), FRESH_SSH (ssh), FRESH_YES=1 (no question): the rig's test sets them.
set -u
mode=${1:-}; alias=${2:-}
domain=${FRESH_KORE_DOMAIN:-dev.kore.Kore}
support=${FRESH_KORE_SUPPORT:-$HOME/Library/Application Support/Kore}
process=${FRESH_KORE_PROCESS:-Kore}
ssh=(${=FRESH_SSH:-ssh} -o BatchMode=yes -o ConnectTimeout=10)
usage() { print -u2 "usage: fresh-box.sh --backup|--wipe <alias> · --restore <alias> <backup folder> · --verify <alias> [--expect fresh|installed]"; exit 2; }
[[ -n $alias && $mode == (--backup|--wipe|--restore|--verify) ]] || usage
[[ $alias =~ '^[A-Za-z0-9._@:][A-Za-z0-9._@:-]*$' ]] || { print -u2 "fresh-box: $alias isn't a box alias"; exit 2; }
# -a: this script may run under a Kore whose process would otherwise be skipped as an ancestor.
if pgrep -a -x "$process" >/dev/null 2>&1; then
    print -u2 "fresh-box: $process is running: quit it first (its settings are rewritten here)"
    exit 1
fi
tool=$(mktemp -d -t fresh-box)
trap 'rm -rf $tool' EXIT

# This Mac's side, in python (plistlib, json): every key and file that names the box.
cat > $tool/mac.py <<'EOF'
import json, os, plistlib, shutil, subprocess, sys
mode, domain, support, alias, folder = sys.argv[1:6]
PREFIXES = ["boxGrant.", "boxKoreHost.", "boxRecents.", "boxRecentsForgotten.", "boxTabGroups.", "boxHostKeys."]
LISTS = ["boxHosts", "koreNetPaused"]
JSONS = ["koreNodes", "koreNodeNames", "koreNodeHostnames", "syncPairs"]

def load():
    out = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    return plistlib.loads(out.stdout) if out.returncode == 0 and out.stdout else {}

def save(prefs):
    path = os.path.join(os.environ["TOOL"], "prefs-new.plist")
    with open(path, "wb") as f: plistlib.dump(prefs, f, fmt=plistlib.FMT_XML)
    subprocess.run(["defaults", "import", domain, path], check=True)

def decoded(v):
    if isinstance(v, (bytes, bytearray)):
        try: return json.loads(v), True
        except Exception: return None, True
    return v, False

def names_of(prefs):
    names = {alias}
    nodes, _ = decoded(prefs.get("koreNodes", b"{}"))
    for _ in range(2):
        for key, entry in (nodes or {}).items():
            if key in names or (isinstance(entry, dict) and entry.get("ssh") in names):
                names.add(key)
                if isinstance(entry, dict) and entry.get("ssh"): names.add(entry["ssh"])
    return names

def mentions(item, names):
    if isinstance(item, str): return item in names or item.lower() in names
    if isinstance(item, dict): return any(mentions(v, names) for v in item.values() if isinstance(v, str))
    return False

def take(prefs, names):
    """The box's part of the settings, and the settings without it."""
    part = {"keys": {}, "lists": {}, "json": {}}
    for key in list(prefs):
        if any(key == p + n for p in PREFIXES for n in names):
            part["keys"][key] = prefs.pop(key)
    for key in LISTS:
        if isinstance(prefs.get(key), list):
            part["lists"][key] = [i for i in prefs[key] if mentions(i, names)]
            prefs[key] = [i for i in prefs[key] if not mentions(i, names)]
    for key in JSONS:
        if key not in prefs: continue
        value, wrapped = decoded(prefs[key])
        if isinstance(value, dict):
            mine = {k: v for k, v in value.items() if k in names or k.lower() in names or mentions(v, names)}
            rest = {k: v for k, v in value.items() if k not in mine}
        elif isinstance(value, list):
            mine = [i for i in value if mentions(i, names)]
            rest = [i for i in value if not mentions(i, names)]
        else:
            continue
        part["json"][key] = {"value": mine, "data": wrapped}
        prefs[key] = json.dumps(rest).encode() if wrapped else rest
    return part

def put(prefs, part):
    prefs.update(part["keys"])
    for key, items in part["lists"].items():
        have = prefs.get(key, [])
        prefs[key] = have + [i for i in items if i not in have]
    for key, held in part["json"].items():
        value, _ = decoded(prefs[key]) if key in prefs else (None, held["data"])
        mine = held["value"]
        if isinstance(mine, dict): value = {**(value or {}), **mine}
        else: value = (value or []) + mine
        prefs[key] = json.dumps(value).encode() if held["data"] else value

def files_of(names, ids):
    paths = [os.path.join("hosts", n) for n in names] + [os.path.join("nodes", i) for i in ids]
    mig = os.path.join(support, "nodes", "migrations")
    for name in (os.listdir(mig) if os.path.isdir(mig) else []):
        try: journal = json.load(open(os.path.join(mig, name)))
        except Exception: continue
        if journal.get("from") in names or str(journal.get("to", "")).lower() in ids: paths.append(os.path.join("nodes", "migrations", name))
    return [p for p in paths if os.path.exists(os.path.join(support, p))]

def book_take(ids, keep):
    path = os.path.join(support, "net", "devices.json")
    if not os.path.exists(path): return []
    book = json.load(open(path))
    devices = book.get("devices", []) if isinstance(book, dict) else book
    mine = [d for d in devices if str(d.get("id", "")).lower() in ids and d.get("kind") == "box"]
    if not keep and mine:
        rest = [d for d in devices if d not in mine]
        if isinstance(book, dict): book["devices"] = rest
        else: book = rest
        json.dump(book, open(path, "w"))
        os.chmod(path, 0o600)
    return mine

def wipe_now(say):
    prefs = load()
    names = names_of(prefs)
    ids = {n.lower() for n in names if len(n) == 36 and n.count("-") == 4}
    part = take(prefs, names)
    files = files_of(names, ids)
    records = book_take(ids, keep=(mode == "plan" or mode == "backup"))
    if say:
        print("  this Mac: " + ", ".join(sorted(names)))
        for k in sorted(part["keys"]): print("    setting " + k)
        for k, v in part["lists"].items():
            if v: print("    in %s: %s" % (k, ", ".join(map(str, v))))
        for k, v in part["json"].items():
            if v["value"]: print("    in %s: %d item(s)" % (k, len(v["value"])))
        for f in files: print("    file Kore/" + f)
        for r in records: print("    record %s (%s) in Kore/net/devices.json" % (r.get("id"), r.get("name")))
    return prefs, names, part, files, records

if mode == "plan":
    wipe_now(True)
elif mode == "backup":
    prefs, names, part, files, records = wipe_now(True)
    json.dump({"alias": alias, "names": sorted(names), "settings": part, "records": records, "files": files}, open(os.path.join(folder, "mac.json"), "w"), default=str)
    for f in files:
        src, dst = os.path.join(support, f), os.path.join(folder, "mac-files", f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, dst)
elif mode == "wipe":
    prefs, names, part, files, records = wipe_now(False)
    save(prefs)
    for f in files:
        p = os.path.join(support, f)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    print("  this Mac: forgot %s" % ", ".join(sorted(names)))
elif mode == "restore":
    held = json.load(open(os.path.join(folder, "mac.json")))
    prefs = load()
    put(prefs, held["settings"])
    save(prefs)
    for f in held["files"]:
        src, dst = os.path.join(folder, "mac-files", f), os.path.join(support, f)
        if os.path.exists(dst): shutil.rmtree(dst) if os.path.isdir(dst) else os.remove(dst)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        (shutil.copytree if os.path.isdir(src) else shutil.copy2)(src, dst)
    if held["records"]:
        path = os.path.join(support, "net", "devices.json")
        book = json.load(open(path)) if os.path.exists(path) else {"devices": []}
        devices = book.get("devices", []) if isinstance(book, dict) else book
        ids = {str(r.get("id")).lower() for r in held["records"]}
        devices = [d for d in devices if str(d.get("id", "")).lower() not in ids] + held["records"]
        if isinstance(book, dict): book["devices"] = devices
        else: book = devices
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(book, open(path, "w"))
        os.chmod(path, 0o600)
    print("  this Mac: restored %s" % ", ".join(held["names"]))
EOF
mac() { TOOL=$tool python3 -I $tool/mac.py "$1" "$domain" "$support" "$alias" "${2:-$tool}"; }

box_paths='.local/state/kore-host .local/bin/kore-host .local/bin/kore-tailnet .config/systemd/user/kore-host.service .config/kore-host'
# The box's side: what's there of kore-host, and its own node's name.
box_plan="cd; for p in $box_paths; do [ -e \$p ] && echo \"  box: ~/\$p\"; done; echo \"  box: tailnet node \$(hostname -s)-kore\"; true"
box_wipe="cd; k=.local/bin/kore-host
[ -x \$k ] && \$k uninstall >/dev/null 2>&1
pkill -u \$(id -u) -x kore-host 2>/dev/null; pkill -u \$(id -u) -x kore-tailnet 2>/dev/null; sleep 0.5
systemctl --user daemon-reload 2>/dev/null
rm -rf $box_paths; echo '  box: kore-host removed'"
box_restore="cd; tar xzf - && { [ -x .local/bin/kore-host ] && .local/bin/kore-host install-service >/dev/null 2>&1; echo '  box: restored, kore-host started'; }"

case $mode in
--verify)
    expect=fresh
    [[ ${3:-} == --expect && -n ${4:-} ]] && expect=$4
    [[ $expect == (fresh|installed) ]] || usage
    print "Clean slate for $alias (expect: $expect):"
    bad=0
    mark() { if [[ $2 == ok ]]; then print "  ✔ $1"; else print "  ✘ $1${3:+ · $3}"; (( bad++ )); fi }
    said=$("${ssh[@]}" "$alias" "cd
b=0; [ -e .local/bin/kore-host ] && b=1; echo bin=\$b
u=0; [ -e .config/systemd/user/kore-host.service ] && u=1; echo unit=\$u
echo procs=\$(pgrep -u \$(id -u) -x kore-host | wc -l)
s=0; [ -e .local/state/kore-host ] && s=1; echo state=\$s
echo tnprocs=\$(pgrep -u \$(id -u) -x kore-tailnet | wc -l)
t=0; [ -e .local/state/kore-host/tailnet ] && t=1; echo own=\$t
if command -v tailscaled >/dev/null 2>&1 || [ -e /usr/sbin/tailscaled ]; then systemctl is-active --quiet tailscaled && echo tailscaled=running || echo tailscaled=stopped; else echo tailscaled=absent; fi
systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || pgrep -x sshd >/dev/null && echo sshd=running || echo sshd=stopped
echo timers=\$(systemctl list-units --all --plain --no-legend 'kore-rig-*' 2>/dev/null | wc -l)
if [ \$(id -u) = 0 ]; then echo rules=\$(iptables -S 2>/dev/null | grep -vc '^-P'); elif sudo -n true 2>/dev/null; then echo rules=\$(sudo -n iptables -S 2>/dev/null | grep -vc '^-P'); else echo rules=unknown; fi
for p in ${FRESH_EXPECT_ALIVE:-}; do pgrep -f \"\$p\" >/dev/null && echo alive_\$p=1 || echo alive_\$p=0; done") || { print "  ✘ ssh $alias failed"; exit 1; }
    typeset -A got
    for line in ${(f)said}; do got[${line%%=*}]=${line#*=}; done
    if [[ $expect == fresh ]]; then
        mark "no kore-host binary" $([[ ${got[bin]} == 0 ]] && echo ok)
        mark "no kore-host unit" $([[ ${got[unit]} == 0 ]] && echo ok)
        mark "no kore-host process" $([[ ${got[procs]// /} == 0 ]] && echo ok) "${got[procs]// /} running"
        mark "no ~/.local/state/kore-host" $([[ ${got[state]} == 0 ]] && echo ok)
    else
        mark "kore-host installed" $([[ ${got[bin]} == 1 ]] && echo ok)
        mark "one kore-host running" $([[ ${got[procs]// /} == 1 ]] && echo ok) "${got[procs]// /} running"
    fi
    mark "no kore-tailnet process" $([[ ${got[tnprocs]// /} == 0 || $expect == installed ]] && echo ok) "${got[tnprocs]// /} running"
    [[ $expect == fresh ]] && mark "no own-node state" $([[ ${got[own]} == 0 ]] && echo ok)
    if [[ -n ${FRESH_EXPECT_TAILSCALED:-} ]]; then
        mark "tailscaled ${FRESH_EXPECT_TAILSCALED}" $([[ ${got[tailscaled]} == $FRESH_EXPECT_TAILSCALED ]] && echo ok) "it's ${got[tailscaled]}"
    else
        print "  · tailscaled ${got[tailscaled]}"
    fi
    mark "sshd running" $([[ ${got[sshd]} == running ]] && echo ok)
    mark "no kore-rig-* timers or units" $([[ ${got[timers]// /} == 0 ]] && echo ok) "${got[timers]// /} left"
    if [[ ${got[rules]} == unknown ]]; then print "  · firewall rules not readable here (no root, no sudo -n)"; else mark "no firewall rules beyond the policy" $([[ ${got[rules]// /} == 0 ]] && echo ok) "${got[rules]// /} rules"; fi
    for p in ${FRESH_EXPECT_ALIVE:-}; do mark "$p still running" $([[ ${got[alive_$p]} == 1 ]] && echo ok); done
    if [[ $expect == fresh ]]; then
        left=$(mac plan | grep -vc "this Mac: ")
        mark "this Mac's Kore has no trace of $alias" $([[ $left == 0 ]] && echo ok) "$(mac plan | grep -v 'this Mac: ' | tr -s ' ' | tr '\n' ';')"
    fi
    leftover=(${~${FRESH_TEST_SSH_GLOB:-/tmp/kr-*/ssh_config}}(N))
    mark "no test ssh config left" $([[ ${#leftover} == 0 ]] && echo ok) "${leftover[*]}"
    (( bad == 0 )) && print "clean: $alias" || print "not clean: $alias ($bad)"
    exit $(( bad > 0 ))
    ;;
--backup)
    out="$HOME/Library/Application Support/KoreDev/fresh-box/$alias-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$out" && chmod 700 "$out"
    print "Backing up $alias into $out:"
    mac backup "$out" || exit 1
    "${ssh[@]}" "$alias" "$box_plan" || { print -u2 "fresh-box: ssh $alias failed"; exit 1; }
    "${ssh[@]}" "$alias" "cd; tar czf - \$(for p in $box_paths; do [ -e \$p ] && echo \$p; done) 2>/dev/null" > "$out/box.tgz" || exit 1
    print "  box: $(( $(stat -f %z "$out/box.tgz") / 1024 )) KB"
    print "$out"
    ;;
--wipe)
    print "Wiping $alias (Kore will never have seen it; the box keeps nothing of kore-host):"
    mac plan || exit 1
    "${ssh[@]}" "$alias" "$box_plan" || { print -u2 "fresh-box: ssh $alias failed"; exit 1; }
    if [[ ${FRESH_YES:-} != 1 ]]; then
        print -n "Type yes to wipe: "
        read -r answer
        [[ $answer == yes ]] || { print "Nothing changed."; exit 1; }
    fi
    mac wipe || exit 1
    "${ssh[@]}" "$alias" "$box_wipe"
    print "  Remove the node $("${ssh[@]}" "$alias" 'hostname -s')-kore in the admin console (Kore can't delete a tailnet node)."
    ;;
--restore)
    from=${3:-}
    [[ -f $from/mac.json && -f $from/box.tgz ]] || { print -u2 "fresh-box: $from isn't a backup (mac.json, box.tgz)"; exit 2; }
    print "Restoring $alias from $from (what's there now goes first):"
    mac wipe >/dev/null || exit 1
    "${ssh[@]}" "$alias" "$box_wipe" >/dev/null
    mac restore "$from" || exit 1
    "${ssh[@]}" "$alias" "$box_restore" < "$from/box.tgz" || exit 1
    ;;
esac
