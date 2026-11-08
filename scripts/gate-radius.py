#!/usr/bin/env python3
"""scripts/gate-radius.py <src> <changed-files-file> <dump-package.json>

The blast radius of a change for verify-fast.sh --radius: which Swift test targets, storylines
and Android checks it can reach. Prints shell assignments (eval'd by the gate):

  radius_full=0|1          1: the change touches shared code, so the full check runs
  radius_why='…'           one line: why full, or what the radius is
  radius_tests='A B'       Swift test targets (Tests/<name>) to run
  radius_stories='X,Y'     storyline names to run (with --tag gate); empty: none beyond the smoke set
  radius_all_stories=0|1   1: every gate storyline
  radius_android=0|1       1: android/ changed

Rules (gate-radius.map, beside this file, holds the storyline areas):
- A changed file maps to its SwiftPM target (Sources/<path> or Tests/<name>); every target that
  depends on it, directly or through others, is reached; every test target reached runs.
- Shared code (LinkProtocol, src, KoreCore), Package.swift, Package.resolved, scripts/ and
  Tests/Fixtures make the check full.
- Storylines: a UI area's path maps to its catalogue files (the map); a catalogue file runs its
  own storylines; the storyline engine, or a UI path the map doesn't know, runs every gate
  storyline. The smoke set (in the map) always runs.
- android/ runs the Android check, and nothing else asks for it.
- Docs (z-docs/, *.md outside Sources) reach nothing.
"""
import json
import os
import re
import sys

src, changed_path, dump_path = sys.argv[1:4]
changed = [l.strip() for l in open(changed_path) if l.strip()]
package = json.load(open(dump_path))
here = os.path.dirname(os.path.abspath(__file__))

SHARED = {"LinkProtocol", "src", "KoreCore"}
FULL_PATHS = ("Package.swift", "Package.resolved", "scripts/", "Tests/Fixtures/")

# Targets: name -> (path, direct target dependencies).
targets = {}
for t in package["targets"]:
    deps = []
    for d in t.get("dependencies", []):
        kind = next(iter(d))
        value = d[kind]
        name = value[0] if isinstance(value, list) else value
        if kind in ("byName", "target"):
            deps.append(name)
    base = "Tests" if t["type"] == "test" else "Sources"
    targets[t["name"]] = (t.get("path") or f"{base}/{t['name']}", deps, t["type"])

def owner(path):
    best = None
    for name, (tpath, _, _) in targets.items():
        prefix = tpath.rstrip("/") + "/"
        if path.startswith(prefix) and (best is None or len(prefix) > len(targets[best][0]) + 1):
            best = name
    return best

# Reverse edges, then every dependent of the changed targets.
dependents = {name: set() for name in targets}
for name, (_, deps, _) in targets.items():
    for d in deps:
        if d in dependents:
            dependents[d].add(name)

def reach(start):
    seen, todo = set(start), list(start)
    while todo:
        for n in dependents.get(todo.pop(), ()):
            if n not in seen:
                seen.add(n)
                todo.append(n)
    return seen

# The storyline map: "<path prefix>\t<catalogue files without Storylines.swift, space-separated | ALL>"
# and "smoke\t<story names>".
areas, smoke = [], []
for line in open(os.path.join(here, "gate-radius.map")):
    line = line.split("#", 1)[0].rstrip()
    if not line.strip():
        continue
    key, _, value = line.partition("\t")
    if key == "smoke":
        smoke += value.split()
    else:
        areas.append((key, value.split()))
areas.sort(key=lambda a: -len(a[0]))

catalogue = os.path.join(src, "Sources/KoreStorylines/Catalogue")
def stories_in(stem):
    path = os.path.join(catalogue, stem + ".swift")
    if not os.path.exists(path):
        path = os.path.join(catalogue, stem + "Storylines.swift")
    if not os.path.exists(path):
        return []
    text = open(path).read()
    return re.findall(r"^final class (\w+)\s*:", text, re.M)

full, why = False, []
touched, android = set(), False
story_files, all_stories = set(), False
for path in changed:
    if path.startswith("android/"):
        android = True
        continue
    if path.startswith("z-docs/") or (path.endswith(".md") and not path.startswith("Sources/")):
        continue
    if path.startswith(FULL_PATHS) or path in FULL_PATHS:
        full = True
        why.append(path)
        continue
    target = owner(path)
    if target is None:
        continue
    touched.add(target)
    if target in SHARED:
        full = True
        why.append(f"{path} ({target})")
        continue
    if target == "KoreStorylines":
        rel = path[len("Sources/KoreStorylines/"):]
        if rel.startswith("Catalogue/"):
            story_files.add(os.path.splitext(os.path.basename(rel))[0])
        else:
            all_stories = True
        continue
    # A path in a UI area, or a target the map names (HostClient/, KoreLink/, …).
    hit = next((files for prefix, files in areas if path.startswith(prefix)), None)
    if hit is None and targets[target][2] != "test" and "KoreUI" in reach({target}) | {target}:
        # Code the app's windows use that no area names: every gate storyline.
        all_stories = True
    elif hit == ["ALL"]:
        all_stories = True
    elif hit:
        story_files.update(hit)

reached = reach(touched)
tests = sorted(n for n in reached if targets[n][2] == "test")
stories = sorted({s for f in story_files for s in stories_in(f)} | set(smoke))

def q(s):
    return "'" + s.replace("'", "'\\''") + "'"

if full:
    print("radius_full=1")
    print("radius_why=" + q("shared: " + ", ".join(why[:4]) + (" …" if len(why) > 4 else "")))
else:
    print("radius_full=0")
    print("radius_why=" + q(f"{len(changed)} files; targets {' '.join(sorted(touched)) or '-'}"))
print("radius_tests=" + q(" ".join(tests)))
print("radius_stories=" + q(",".join(stories)))
print(f"radius_all_stories={1 if all_stories else 0}")
print(f"radius_android={1 if android else 0}")
