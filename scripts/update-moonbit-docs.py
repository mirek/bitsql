#!/usr/bin/env python3
"""Refresh the vendored MoonBit reference docs under docs/moonbit/.

Idempotent and safe to rerun whenever a new MoonBit toolchain, docs revision
or moonbitlang/async release appears. Stdlib only.

Sources (all fetched fresh, shallow):
  * moonbitlang/moonbit-docs  -> docs/moonbit/language, docs/moonbit/toolchain
      `{literalinclude}` directives are resolved inline so each page is
      self-contained (the upstream pages are mostly includes).
  * moonbitlang/skills        -> docs/moonbit/agent-guide (moonbit-agent-guide skill)
  * moonbitlang/async @ tag   -> docs/moonbit/async (README, examples index, every
                                 package's pkg.generated.mbti)
  * local toolchain core lib  -> docs/moonbit/core-api (every pkg.generated.mbti
                                 of ~/.moon/lib/core, matching the installed moonc)

Writes docs/moonbit/VERSIONS.md recording exactly what was fetched.

Usage:
  scripts/update-moonbit-docs.py                # latest async from registry
  scripts/update-moonbit-docs.py --async-version 0.22.4
  scripts/update-moonbit-docs.py --keep-tmp     # leave clones for inspection
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "moonbit"

DOCS_REPO = "https://github.com/moonbitlang/moonbit-docs.git"
SKILLS_REPO = "https://github.com/moonbitlang/skills.git"
ASYNC_REPO = "https://github.com/moonbitlang/async.git"

# Pages from moonbit-docs/next worth vendoring. Others (tutorials, wasm
# component model, examples) are irrelevant to this project.
LANGUAGE_PAGES = [
    "introduction", "fundamentals", "methods", "derive", "error-handling",
    "packages", "tests", "benchmarks", "docs", "attributes", "ffi",
    "async-experimental", "lexical-conventions",
]
TOOLCHAIN_PAGES = [
    "moon/index", "moon/tutorial", "moon/commands", "moon/module", "moon/package",
    "moon/workspace", "moon/coverage", "moon/package-manage-tour", "moonide/index",
]


def run(cmd: list[str], cwd: Path | None = None) -> str:
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def clone(url: str, dest: Path, ref: str | None = None) -> str:
    cmd = ["git", "clone", "--depth", "1", "--quiet"]
    if ref:
        cmd += ["--branch", ref]
    run(cmd + [url, str(dest)])
    return run(["git", "log", "-1", "--format=%H %cs"], cwd=dest)


# --- literalinclude resolution -------------------------------------------------

FENCE_RE = re.compile(r"^(?P<indent>\s*)(?P<fence>`{3,})\{literalinclude\}\s+(?P<path>\S+)\s*$")


def dedent(lines: list[str]) -> list[str]:
    widths = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    n = min(widths) if widths else 0
    return [l[n:] if l.strip() else "" for l in lines]


def slice_include(text: str, opts: dict[str, str]) -> list[str]:
    lines = text.splitlines()
    if "start-after" in opts:
        idx = next((i for i, l in enumerate(lines) if opts["start-after"] in l), None)
        lines = lines[idx + 1:] if idx is not None else lines
    if "end-before" in opts:
        idx = next((i for i, l in enumerate(lines) if opts["end-before"] in l), None)
        lines = lines[:idx] if idx is not None else lines
    if "lines" in opts:
        picked: list[str] = []
        for part in opts["lines"].split(","):
            a, _, b = part.partition("-")
            lo = int(a) - 1
            hi = int(b) if b else int(a)
            picked += lines[lo:hi]
        lines = picked
    if "dedent" in opts:
        lines = dedent(lines)
    # drop MoonBit block separators: noise for a reader
    return [l for l in lines if l.strip() != "///|"]


def resolve_includes(md: str, docs_root: Path, page: Path) -> str:
    out: list[str] = []
    src = md.splitlines()
    i = 0
    while i < len(src):
        m = FENCE_RE.match(src[i])
        if not m:
            out.append(src[i])
            i += 1
            continue
        indent, fence, path = m["indent"], m["fence"], m["path"]
        opts: dict[str, str] = {}
        i += 1
        while i < len(src) and src[i].strip() != fence:
            opt = src[i].strip()
            if opt.startswith(":"):
                key, _, val = opt[1:].partition(":")
                opts[key.strip()] = val.strip()
            i += 1
        i += 1  # closing fence
        target = docs_root / path.lstrip("/") if path.startswith("/") else page.parent / path
        lang = opts.get("language", "")
        if not target.exists():
            out.append(f"{indent}<!-- unresolved include: {path} -->")
            continue
        body = slice_include(target.read_text(encoding="utf-8"), opts)
        out.append(f"{indent}```{lang}")
        out += [indent + l if l else "" for l in body]
        out.append(f"{indent}```")
    return "\n".join(out) + "\n"


# --- sections ------------------------------------------------------------------

HEADER = "<!-- GENERATED by scripts/update-moonbit-docs.py from {src} -- do not edit; rerun the script -->\n\n"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def sync_docs(tmp: Path) -> str:
    rev = clone(DOCS_REPO, tmp / "moonbit-docs")
    next_root = tmp / "moonbit-docs" / "next"
    for group, pages in (("language", LANGUAGE_PAGES), ("toolchain", TOOLCHAIN_PAGES)):
        for name in pages:
            page = next_root / group / f"{name}.md"
            if not page.exists():
                print(f"  ! missing upstream page {group}/{name}.md (renamed?)", file=sys.stderr)
                continue
            text = resolve_includes(page.read_text(encoding="utf-8"), next_root, page)
            dest = OUT / group / (name.replace("/", "-") + ".md")
            write(dest, HEADER.format(src=f"moonbit-docs next/{group}/{name}.md") + text)
    # error code index is large; keep only the listing of codes -> titles
    codes_dir = next_root / "language" / "error_codes"
    if codes_dir.is_dir():
        rows = []
        for f in sorted(codes_dir.glob("E*.md")):
            first = next((l for l in f.read_text(encoding="utf-8").splitlines() if l.startswith("#")), f.stem)
            rows.append(f"- {first.lstrip('# ').strip()}")
        write(OUT / "language" / "error-codes-index.md",
              HEADER.format(src="moonbit-docs next/language/error_codes") +
              "# Compiler error/warning codes\n\nUse `moon explain <code>` for details.\n\n" + "\n".join(rows) + "\n")
    return rev


def sync_agent_guide(tmp: Path) -> str:
    rev = clone(SKILLS_REPO, tmp / "skills")
    src = tmp / "skills" / "skills" / "moonbit-agent-guide"
    dest = OUT / "agent-guide"
    for f in ["SKILL.md", "ide.md", "references/moonbit-language-fundamentals.md",
              "references/advanced-moonbit-build.md"]:
        p = src / f
        if p.exists():
            write(dest / Path(f).name, HEADER.format(src=f"moonbitlang/skills moonbit-agent-guide/{f}") +
                  p.read_text(encoding="utf-8"))
    return rev


def latest_async_version() -> str:
    out = run(["moon", "view", "moonbitlang/async"])
    m = re.search(r"Latest:\s*(\S+)", out)
    if not m:
        sys.exit("could not determine latest moonbitlang/async version")
    return m.group(1)


def sync_async(tmp: Path, version: str) -> str:
    rev = clone(ASYNC_REPO, tmp / "async", ref=f"v{version}")
    src = tmp / "async"
    dest = OUT / "async"
    write(dest / "README.md", HEADER.format(src=f"moonbitlang/async v{version} README.md") +
          (src / "README.md").read_text(encoding="utf-8"))
    ex = src / "examples" / "README.md"
    if ex.exists():
        write(dest / "examples.md", HEADER.format(src=f"moonbitlang/async v{version} examples/README.md") +
              ex.read_text(encoding="utf-8"))
    for name in ("tcp_echo_server", "tcp_server_benchmark"):
        d = src / "examples" / name
        if d.is_dir():
            body = "".join(f"\n## {f.name}\n\n```moonbit\n{f.read_text(encoding='utf-8')}```\n"
                           for f in sorted(d.iterdir()) if f.is_file())
            write(dest / f"example-{name}.md",
                  HEADER.format(src=f"moonbitlang/async v{version} examples/{name}") + f"# {name}\n" + body)
    api = "".join(f"\n## {m.parent.relative_to(src / 'src') or '.'}\n\n```moonbit\n{m.read_text(encoding='utf-8')}```\n"
                  for m in sorted((src / "src").rglob("pkg.generated.mbti")) if "internal" not in m.parts)
    write(dest / "api.md", HEADER.format(src=f"moonbitlang/async v{version} src/**/pkg.generated.mbti") +
          f"# moonbitlang/async {version} public API\n" + api)
    return rev


def sync_core_api() -> str:
    core = Path(os.environ.get("MOON_HOME", Path.home() / ".moon")) / "lib" / "core"
    version = run(["moonc", "-v"])
    files = sorted(m for m in core.rglob("pkg.generated.mbti")
                   if "_build" not in m.parts and "internal" not in m.parts)
    dest = OUT / "core-api"
    if dest.exists():
        shutil.rmtree(dest)
    index = []
    for m in files:
        pkg = str(m.parent.relative_to(core)) or "."
        name = pkg.replace("/", "-")
        write(dest / f"{name}.mbti", m.read_text(encoding="utf-8"))
        index.append(f"- [`moonbitlang/core/{pkg}`]({name}.mbti)")
    write(dest / "INDEX.md", HEADER.format(src=f"{core} (moonc {version})") +
          f"# moonbitlang/core API ({version})\n\n" + "\n".join(index) + "\n")
    return version


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--async-version", help="moonbitlang/async version (default: latest in registry)")
    ap.add_argument("--keep-tmp", action="store_true")
    args = ap.parse_args()

    tmp = Path(tempfile.mkdtemp(prefix="moonbit-docs-"))
    try:
        for sub in ("language", "toolchain", "agent-guide", "async"):
            if (OUT / sub).exists():
                shutil.rmtree(OUT / sub)
        print("moonbit-docs ...");     docs_rev = sync_docs(tmp)
        print("agent guide ...");      skills_rev = sync_agent_guide(tmp)
        async_version = args.async_version or latest_async_version()
        print(f"async {async_version} ..."); async_rev = sync_async(tmp, async_version)
        print("core api ...");         core_version = sync_core_api()
        moon_version = run(["moon", "version"]).splitlines()[0]
        today = dt.date.today().isoformat()
        write(OUT / "VERSIONS.md", f"""# Vendored MoonBit docs: versions

Generated by `scripts/update-moonbit-docs.py` on {today}. Rerun it to refresh;
see `.claude/skills/moonbit-docs-update/SKILL.md` for the full procedure.

| Source | Revision |
| --- | --- |
| toolchain (`moon version`) | `{moon_version}` |
| compiler / core (`moonc -v`) | `{core_version}` |
| moonbitlang/moonbit-docs (next/) | `{docs_rev}` |
| moonbitlang/skills (moonbit-agent-guide) | `{skills_rev}` |
| moonbitlang/async | `v{async_version}` (`{async_rev}`) |
""")
        print(f"done -> {OUT.relative_to(ROOT)}")
    finally:
        if args.keep_tmp:
            print(f"clones kept in {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
