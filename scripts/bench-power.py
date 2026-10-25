#!/usr/bin/env python3
"""Compare already-built kore-power-bench binaries without compiling during CPU intervals.

Example: scripts/bench-power.py --before /tmp/old/kore-power-bench \
    --after .build/release/kore-power-bench --out /tmp/kore-power-results
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import statistics
import subprocess
import time


def ready_line(process, output, timeout=45):
    # One readiness event, not a periodic observer of the target's UI.
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        lines = []
        while time.monotonic() < deadline:
            if not selector.select(max(0, deadline - time.monotonic())):
                break
            line = process.stdout.readline()
            if not line:
                break
            output.write(line)
            output.flush()
            lines.append(line)
            try:
                if json.loads(line).get("event") == "ready":
                    return lines
            except json.JSONDecodeError:
                pass
    raise RuntimeError("benchmark did not become ready")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--fixtures", default="track,transcript")
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--hidden", action="store_true")
    parser.add_argument("--hidden-tab", action="store_true")
    parser.add_argument("--reduce-motion", action="store_true")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    binaries = {"after": args.after.resolve()}
    if args.before:
        binaries["before"] = args.before.resolve()
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()}
    (args.out / "inputs.json").write_text(json.dumps({
        "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "binary_sha256": hashes, "binaries": {name: str(path) for name, path in binaries.items()},
        "note": "One-core process CPU. Readiness-gated fresh processes; ABBA per fixture. No build/profile in CPU interval."
    }, indent=2) + "\n")
    order = ["before", "after", "after", "before"] if args.before else ["after", "after"]
    rows = []
    for fixture in args.fixtures.split(","):
        for index, variant in enumerate(order):
            label = f"{fixture}-{index + 1}-{variant}"
            environment = {key: value for key, value in os.environ.items() if not key.startswith("KORE_")}
            environment.update(KORE_POWER_FIXTURE=fixture, KORE_POWER_COUNT=str(args.count),
                KORE_POWER_SECONDS=str(args.seconds), KORE_POWER_HIDDEN=str(int(args.hidden)),
                KORE_POWER_HIDDEN_TAB=str(int(args.hidden_tab)))
            # Preserve system Reduce Motion unless the comparison explicitly enables it.
            if args.reduce_motion:
                environment["KORE_POWER_REDUCE_MOTION"] = "1"
            load_start = os.getloadavg()
            with (args.out / (label + ".stderr.log")).open("w") as error:
                with (args.out / (label + ".stdout.jsonl")).open("w") as output:
                    process = subprocess.Popen([str(binaries[variant])], env=environment,
                        stdout=subprocess.PIPE, stderr=error, text=True)
                    try:
                        first = ready_line(process, output)
                        rest, _ = process.communicate(timeout=max(2, args.seconds) + 30)
                    except BaseException:
                        process.terminate()
                        try:
                            remaining, _ = process.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            remaining, _ = process.communicate(timeout=10)
                        output.write(remaining)
                        raise
                    output.write(rest)
            raw = "".join(first) + rest
            if process.returncode:
                raise RuntimeError(f"{label}: process exit {process.returncode}")
            records = [json.loads(line) for line in raw.splitlines() if line.startswith("{")]
            results = [record for record in records if record.get("event") == "result"]
            if len(results) != 1:
                raise RuntimeError(f"{label}: expected one result")
            row = results[0]
            row.update(case=label, variant=variant, load_start=load_start, load_end=os.getloadavg(),
                binary_sha256=hashes[variant])
            rows.append(row)
            with (args.out / "raw.jsonl").open("a") as output:
                output.write(json.dumps(row, sort_keys=True) + "\n")
            print(f"{label}: {row['cpu_percent_one_core']:.3f}% CPU; eligible={row['eligible']}", flush=True)
    summary = []
    for fixture in args.fixtures.split(","):
        for variant in binaries:
            selected = [row for row in rows if row["fixture"] == fixture and row["variant"] == variant and row["eligible"]]
            values = [row["cpu_percent_one_core"] for row in selected]
            summary.append({"fixture": fixture, "variant": variant, "eligible_n": len(values),
                "median": statistics.median(values) if values else None,
                "min": min(values) if values else None, "max": max(values) if values else None})
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    if any(not row["eligible"] for row in rows):
        raise SystemExit("Some intervals were ineligible; retained in raw data, excluded from summaries.")


if __name__ == "__main__":
    main()
