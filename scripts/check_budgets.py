#!/usr/bin/env python3
"""Check a target build against agent.lean's budgets (ADR 0005, ADR 0008).

    check_budgets.py --build build/host --target darwin-arm64 [--update] [--no-bench]

* size: the stripped, statically linked reference agent (`ref_agent`) must stay within the
  recorded size plus `size_margin`;
* performance: `bench` metrics must not regress by more than `perf_margin` (lower is better
  except `codec_mb_s`);
* runtime surface: the Lean runtime symbols (`lean_*`) linked into `ref_agent` must equal the
  manifest in `bundle/runtime-surface/<target>.txt`.

`--update` records the current measurements as the new budgets and manifest.
"""
# @tg: implements:: [[openspec:portable-build#Binary size budget]]
# @tg: implements:: [[openspec:portable-build#Performance budgets]]
# @tg: implements:: [[openspec:portable-build#Runtime surface manifest]]
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUDGETS = ROOT / "bench" / "budgets.json"
SURFACE = ROOT / "bundle" / "runtime-surface"
HIGHER_IS_BETTER = {"codec_mb_s"}
PERF_KEYS = ["cold_start_us", "step_overhead_us", "codec_mb_s", "memory_kb_per_agent"]


def stripped_size(exe: Path, strip: str) -> int:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d) / exe.name
        shutil.copyfile(exe, tmp)
        subprocess.run([strip, str(tmp)], check=True, capture_output=True)
        return tmp.stat().st_size


def runtime_surface(exe: Path, nm: str) -> list[str]:
    # Hidden-visibility runtime functions are local in the executable: count text symbols of any scope.
    out = subprocess.run([nm, str(exe)], check=True, capture_output=True, text=True)
    syms = set()
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[-2] not in ("T", "t"):
            continue
        name = parts[-1].lstrip("_").split(".")[0]
        if name.startswith("lean_"):
            syms.add(name)
    return sorted(syms)


def main() -> int:
    global BUDGETS, SURFACE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build", required=True)
    ap.add_argument("--target", required=True, help="e.g. darwin-arm64, linux-aarch64")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--no-bench", action="store_true", help="skip performance (e.g. emulated targets)")
    ap.add_argument("--allow-missing", action="store_true",
                    help="report instead of failing when a target has no recorded budget yet (new CI runners)")
    ap.add_argument("--strip", default=os.environ.get("STRIP", "strip"))
    ap.add_argument("--nm", default=os.environ.get("NM", "nm"))
    ap.add_argument("--bench-iters", default="3000")
    ap.add_argument("--budgets", default=str(BUDGETS), help="budgets file (tests use a copy)")
    ap.add_argument("--surface-dir", default=str(SURFACE), help="runtime surface manifests (tests use a copy)")
    a = ap.parse_args()
    BUDGETS, SURFACE = Path(a.budgets).resolve(), Path(a.surface_dir).resolve()
    build = Path(a.build)
    budgets = json.loads(BUDGETS.read_text()) if BUDGETS.exists() else {"size_margin": 0.05, "perf_margin": 0.5, "targets": {}}
    tb = budgets["targets"].setdefault(a.target, {})
    os_name = a.target.split("-")[0]
    surface_file = SURFACE / f"{a.target}.txt"
    failures = []

    ref = build / "ref_agent"
    size = stripped_size(ref, a.strip)
    surface = runtime_surface(ref, a.nm)
    perf = None
    if not a.no_bench:
        out = subprocess.run([str(build / "bench"), a.bench_iters], check=True, capture_output=True, text=True)
        perf = json.loads(out.stdout.strip().splitlines()[-1])

    print(f"{a.target}: ref_agent stripped = {size} bytes; runtime symbols = {len(surface)}")
    if perf:
        print(f"{a.target}: " + ", ".join(f"{k}={perf[k]}" for k in PERF_KEYS))

    if a.update:
        tb["size_bytes"] = size
        if perf:
            tb["perf"] = {k: perf[k] for k in PERF_KEYS}
        BUDGETS.parent.mkdir(exist_ok=True)
        BUDGETS.write_text(json.dumps(budgets, indent=2, sort_keys=True) + "\n")
        SURFACE.mkdir(parents=True, exist_ok=True)
        surface_file.write_text("\n".join(surface) + "\n")
        print(f"updated {BUDGETS} and {surface_file}")
        return 0

    if "size_bytes" in tb:
        limit = tb["size_bytes"] * (1 + budgets["size_margin"])
        if size > limit:
            failures.append(f"size {size} > budget {tb['size_bytes']} (+{budgets['size_margin']:.0%})")
    elif not a.allow_missing:
        failures.append(f"no size budget for {a.target}; run with --update")
    if perf and "perf" in tb:
        m = budgets["perf_margin"]
        for k in PERF_KEYS:
            base, cur = tb["perf"][k], perf[k]
            if k in HIGHER_IS_BETTER:
                if cur < base * (1 - m):
                    failures.append(f"{k} {cur} < {base} (-{m:.0%})")
            elif cur > base * (1 + m):
                failures.append(f"{k} {cur} > {base} (+{m:.0%})")
    if surface_file.exists():
        want = [l for l in surface_file.read_text().splitlines() if l]
        added, removed = sorted(set(surface) - set(want)), sorted(set(want) - set(surface))
        if added or removed:
            failures.append(f"runtime surface changed: +{added} -{removed} (update {surface_file})")
    elif not a.allow_missing:
        failures.append(f"no runtime surface manifest {surface_file}; run with --update")

    for f in failures:
        print(f"FAIL {a.target}: {f}")
    if not failures:
        print(f"{a.target}: within budgets")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
