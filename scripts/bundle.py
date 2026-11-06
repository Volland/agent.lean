#!/usr/bin/env python3
"""Produce agent.lean's self-contained source bundle.

The bundle is plain C/C++ that builds with CMake and a stock compiler, with no Lean installed:

* generated C for the given root modules and their *runtime* import closure (meta imports are
  compile-time only and never enter the bundle),
* C regenerated from the pinned toolchain's own sources for the Init/Std modules in that closure,
* the pinned Lean runtime sources without libuv, OpenSSL, GMP and mimalloc, plus a POSIX shim,
* stubs for initializers of modules outside the closure, a manifest and a CMakeLists.txt.

The closure doubles as the runtime import allowlist check: a runtime import of `Lean`, `Lake` or a
`Std` module outside `bundle/std-allowlist.txt` fails with the import chain.
"""
# @tg: implements:: [[adr:0008]]
# @tg: implements:: [[openspec:portable-build#Source bundle]]
# @tg: implements:: [[openspec:portable-build#Runtime import allowlist]]
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHIM = ROOT / "bundle" / "shim"

# Runtime files of the pinned Lean runtime that the bundle compiles. libuv.cpp is replaced by an
# overlay; the uv/ event loop, openssl.cpp and mimalloc.cpp are left out on purpose.
RUNTIME_CPP = [
    "debug.cpp", "thread.cpp", "mpz.cpp", "utf8.cpp", "object.cpp", "apply.cpp", "exception.cpp",
    "interrupt.cpp", "memory.cpp", "stackinfo.cpp", "compact.cpp", "init_module.cpp", "io.cpp",
    "hash.cpp", "byteslice.cpp", "platform.cpp", "alloc.cpp", "allocprof.cpp", "sharecommon.cpp",
    "stack_overflow.cpp", "process.cpp", "object_ref.cpp", "mpn.cpp", "mutex.cpp",
]
# @tg: implements:: [[adr:0013]]
# Exact source patches applied to the pinned runtime; each must match or the bundle fails, so a
# toolchain bump cannot silently drop one.
RUNTIME_PATCHES = [
    # iOS has no system(); the call only serves the interactive "attach gdb" debug prompt.
    ("debug.cpp", "if (system(buffer.str().c_str()) == 0) {",
     "if (agentlean_system(buffer.str().c_str()) == 0) {"),
    ("debug.cpp", "namespace lean {",
     "#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n"
     "static int agentlean_system(const char * cmd) {\n"
     "#if defined(__APPLE__) && TARGET_OS_IPHONE\n    (void)cmd; return -1;\n#else\n    return system(cmd);\n#endif\n}\n"
     "namespace lean {"),
]
TOOLCHAIN_PREFIXES = ("Init", "Std", "Lean", "Lake")
FORBIDDEN_PREFIXES = ("Lean", "Lake")

HEADER_IMPORTS = re.compile(r"^// Imports:(.*)$", re.M)
HEADER_MODULE = re.compile(r"^// Module: (\S+)", re.M)
INIT_DECL = re.compile(r"lean_object\* ((?:runtime_|meta_)?initialize_\w+)\(uint8_t builtin\);")
INIT_DEF = re.compile(r"LEAN_EXPORT lean_object\* ((?:runtime_|meta_)?initialize_\w+)\(uint8_t builtin\) ?\{")


def fail(msg: str) -> None:
    print(f"bundle: error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: list[str], **kw) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def parse_imports(c_text: str) -> list[tuple[str, bool]]:
    """Return (module, is_runtime) pairs from a generated C file's `// Imports:` header."""
    m = HEADER_IMPORTS.search(c_text[:20000])
    if not m:
        return []
    toks = m.group(1).split()
    out, meta, i = [], False, 0
    while i < len(toks):
        t = toks[i]
        if t == "public":
            pass
        elif t == "meta":
            meta = True
        elif t == "import":
            i += 1
            if i < len(toks) and toks[i] == "all":
                i += 1
            out.append((toks[i], not meta))
            meta = False
        i += 1
    return out


def is_toolchain(mod: str) -> bool:
    return mod.split(".")[0] in TOOLCHAIN_PREFIXES


class Bundler:
    def __init__(self, args):
        self.args = args
        self.project = Path(args.project).resolve()
        self.out = Path(args.out).resolve()
        self.prefix = Path(run(["lean", "--print-prefix"], cwd=self.project).strip())
        self.version = run(["lean", "--version"], cwd=self.project).strip()
        self.tag = (self.project / "lean-toolchain").read_text().strip().split(":")[-1]
        self.cache = self.project / ".lake" / "agentlean-bundle" / self.tag
        self.allow = self.load_allowlist()
        self.project_c: dict[str, Path] = {}
        self.parent: dict[str, str | None] = {}

    def load_allowlist(self) -> list[str]:
        f = Path(self.args.std_allowlist)
        if not f.exists():
            return []
        lines = [l.split("#")[0].strip() for l in f.read_text().splitlines()]
        return [l for l in lines if l]

    # ---- sources -------------------------------------------------------------------------------
    def index_project_c(self) -> None:
        dirs = [self.project / ".lake" / "build" / "ir"]
        pkgs = self.project / ".lake" / "packages"
        if pkgs.exists():
            dirs += [p / ".lake" / "build" / "ir" for p in pkgs.iterdir()]
        for d in dirs:
            for c in d.rglob("*.c") if d.exists() else []:
                head = c.read_text(errors="replace")[:400]
                m = HEADER_MODULE.search(head)
                if m:
                    self.project_c[m.group(1)] = c

    def toolchain_c(self, mod: str) -> Path:
        out = self.cache / "toolchain-c" / (mod + ".c")
        if out.exists():
            return out
        out.parent.mkdir(parents=True, exist_ok=True)
        src = self.prefix / "src" / "lean" / (mod.replace(".", "/") + ".lean")
        if not src.exists():
            fail(f"toolchain source for {mod} not found at {src}")
        env = dict(os.environ, LEAN_PATH=str(self.prefix / "lib" / "lean"))
        tmp = out.with_suffix(".tmp")
        subprocess.run(["lean", f"--root={self.prefix / 'src' / 'lean'}", "-c", str(tmp), str(src)],
                       check=True, env=env, cwd=self.project, capture_output=True)
        tmp.rename(out)
        return out

    def check_allowed(self, mod: str) -> None:
        top = mod.split(".")[0]
        chain = self.chain(mod)
        if top in FORBIDDEN_PREFIXES:
            fail(f"runtime import of {mod} is forbidden (it links the Lean compiler): {chain}")
        if top == "Std" and not any(mod == a or mod.startswith(a + ".") for a in self.allow):
            fail(f"runtime import of {mod} is not in {self.args.std_allowlist}: {chain}")

    def chain(self, mod: str) -> str:
        path, cur = [], mod
        while cur is not None:
            path.append(cur)
            cur = self.parent.get(cur)
        return " -> ".join(reversed(path))

    def closure(self) -> dict[str, Path]:
        files: dict[str, Path] = {}
        frontier = []
        for r in self.args.root:
            if r not in self.project_c:
                fail(f"no generated C for root module {r}; run `lake build {r}` first")
            self.parent[r] = None
            frontier.append(r)
        seen = set(frontier)
        with cf.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            while frontier:
                tool = [m for m in frontier if is_toolchain(m)]
                for m in tool:
                    self.check_allowed(m)
                gen = dict(zip(tool, pool.map(self.toolchain_c, tool)))
                nxt = []
                for m in frontier:
                    path = gen.get(m) or self.project_c.get(m)
                    if path is None:
                        fail(f"no generated C for {m} (imported via {self.chain(m)}); run `lake build`")
                    files[m] = path
                    for dep, runtime in parse_imports(path.read_text(errors="replace")):
                        if runtime and dep not in seen:
                            seen.add(dep)
                            self.parent[dep] = m
                            nxt.append(dep)
                frontier = nxt
        return files

    def lean_src(self) -> Path:
        src = self.cache / "lean4"
        if not (src / "src" / "runtime" / "object.cpp").exists():
            shutil.rmtree(src, ignore_errors=True)
            run(["git", "clone", "-q", "--depth", "1", "--branch", self.tag, "--filter=blob:none",
                 "--sparse", "https://github.com/leanprover/lean4.git", str(src)])
            run(["git", "-C", str(src), "sparse-checkout", "set", "src/runtime", "src/include", "src/util"])
        commit = run(["git", "-C", str(src), "rev-parse", "HEAD"]).strip()
        m = re.search(r"commit ([0-9a-f]+)", self.version)
        if m and not commit.startswith(m.group(1)) and not m.group(1).startswith(commit[:12]):
            fail(f"runtime sources {commit} do not match toolchain commit {m.group(1)}")
        self.commit = commit
        return src / "src"

    # ---- output --------------------------------------------------------------------------------
    def write(self) -> None:
        self.index_project_c()
        files = self.closure()
        src = self.lean_src()
        if self.out.exists():
            shutil.rmtree(self.out)
        (self.out / "lean").mkdir(parents=True)
        decl, defs = set(), set()
        for mod, path in sorted(files.items()):
            text = path.read_text(errors="replace")
            decl |= set(INIT_DECL.findall(text))
            defs |= set(INIT_DEF.findall(text))
            shutil.copyfile(path, self.out / "lean" / (mod + ".c"))
        # runtime
        rt = self.out / "runtime"
        rt.mkdir()
        for h in (src / "runtime").glob("*.h"):
            shutil.copyfile(h, rt / h.name)
        for c in RUNTIME_CPP:
            shutil.copyfile(src / "runtime" / c, rt / c)
        for name, old, new in RUNTIME_PATCHES:
            f = rt / name
            text = f.read_text()
            if old not in text:
                fail(f"runtime patch no longer applies to {name}: {old!r}")
            f.write_text(text.replace(old, new, 1))
        for o in (SHIM / "runtime").iterdir():
            shutil.copyfile(o, rt / o.name)
        (self.out / "util").mkdir()
        for h in (src / "util").glob("*.h"):
            shutil.copyfile(h, self.out / "util" / h.name)
        inc = self.out / "include" / "lean"
        inc.mkdir(parents=True)
        shutil.copyfile(src / "include" / "lean" / "lean.h", inc / "lean.h")
        shutil.copyfile(self.prefix / "include" / "lean" / "version.h", inc / "version.h")
        shutil.copyfile(SHIM / "config.h", inc / "config.h")
        (self.out / "githash.h").write_text(f'#pragma once\n#define LEAN_GITHASH "{self.commit}"\n')
        (self.out / "shim").mkdir()
        for f in ("uv.h", "uv_shim.c"):
            shutil.copyfile(SHIM / f, self.out / "shim" / f)
        # stubs for initializers of modules outside the runtime closure (meta-only imports)
        missing = sorted(decl - defs)
        with open(self.out / "stubs.c", "w") as f:
            f.write("/* Generated by scripts/bundle.py: initializers of compile-time-only modules. */\n")
            f.write("#include <lean/lean.h>\n")
            for s in missing:
                f.write(f"LEAN_EXPORT lean_object* {s}(uint8_t builtin) {{ (void)builtin; "
                        f"return lean_io_result_mk_ok(lean_box(0)); }}\n")
        # app_init.c: run the root modules' runtime initializers (they register the agents)
        inits = []
        for r in self.args.root:
            m = re.search(r"LEAN_EXPORT lean_object\* (runtime_initialize_\w+)\(uint8_t builtin\)", files[r].read_text(errors="replace"))
            if not m:
                fail(f"no runtime initializer found in the C of {r}")
            inits.append(m.group(1))
        with open(self.out / "app_init.c", "w") as f:
            f.write("/* Generated by scripts/bundle.py: initialize the application's root modules. */\n")
            f.write("#include <lean/lean.h>\n#include <stdlib.h>\n")
            for i in inits:
                f.write(f"extern lean_object* {i}(uint8_t builtin);\n")
            f.write("void agent_app_initialize(void) {\n  lean_object* r;\n")
            for i in inits:
                f.write(f"  r = {i}(1);\n  if (lean_io_result_is_error(r)) {{ lean_io_result_show_error(r); abort(); }}\n"
                        "  lean_dec_ref(r);\n")
            f.write("}\n")
        for extra in self.args.extra or []:
            p = Path(extra).resolve()
            dst = self.out / "extra" / p.name
            dst.parent.mkdir(exist_ok=True)
            shutil.copyfile(p, dst)
        for extra in self.args.extra_include or []:
            p = Path(extra).resolve()
            dst = self.out / "extra" / p.name
            dst.parent.mkdir(exist_ok=True)
            shutil.copyfile(p, dst)
        for ex in self.args.example or []:
            p = Path(ex).resolve()
            dst = self.out / "examples" / p.name
            dst.parent.mkdir(exist_ok=True)
            shutil.copyfile(p, dst)
        shutil.copyfile(ROOT / "bundle" / "CMakeLists.txt.in", self.out / "CMakeLists.txt")
        manifest = {
            "toolchain": self.version,
            "tag": self.tag,
            "runtime_commit": self.commit,
            "roots": self.args.root,
            "modules": sorted(files),
            "module_count": len(files),
            "stubbed_initializers": missing,
            "excluded_runtime": ["libuv event loop (uv/*)", "openssl.cpp", "mimalloc", "GMP"],
            "lean_c_bytes": sum((self.out / "lean" / (m + ".c")).stat().st_size for m in files),
        }
        (self.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        digest = hashlib.sha256()
        for p in sorted(self.out.rglob("*")):
            if p.is_file() and p.name != "manifest.json":
                digest.update(p.read_bytes())
        print(f"bundle: {len(files)} modules ({sum(1 for m in files if is_toolchain(m))} from the toolchain), "
              f"{len(missing)} stubbed initializers -> {self.out} (sha256 {digest.hexdigest()[:16]})")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", default=str(ROOT), help="Lake project directory (default: repo root)")
    ap.add_argument("--root", action="append", required=True, help="root module (repeatable)")
    ap.add_argument("--out", default=str(ROOT / "bundle" / "out"), help="output directory")
    ap.add_argument("--std-allowlist", default=str(ROOT / "bundle" / "std-allowlist.txt"))
    ap.add_argument("--extra", action="append", help="extra C/C++ source compiled into the library")
    ap.add_argument("--extra-include", action="append", help="extra header copied next to --extra sources")
    ap.add_argument("--example", action="append", help="C program built as an executable against the library")
    Bundler(ap.parse_args()).write()


if __name__ == "__main__":
    main()
