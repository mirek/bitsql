---
name: moonbit-docs-update
description: Refresh the vendored MoonBit docs (language, toolchain, agent guide, moonbitlang/async API, core API) in docs/moonbit/ and bump pinned MoonBit versions. Use when a new moon/moonc toolchain or moonbitlang/async release is discovered, when `moon` reports a newer version, when the vendored docs disagree with compiler behavior, or periodically (roughly monthly).
---

# Updating MoonBit docs and versions

`docs/moonbit/` is generated. Never hand-edit it; rerun the script.
Project-specific MoonBit knowledge lives in `.claude/skills/moonbit/SKILL.md`,
which the script does not touch.

## 1. Detect what is new

```bash
moon version                      # installed toolchain (moon + moonc)
moonc -v
cat docs/moonbit/VERSIONS.md      # what the vendored docs were built from
moon update && moon view moonbitlang/async   # latest async release
```

To upgrade the toolchain (affects the user's global `~/.moon`, so mention it
in your report): `moon upgrade`. Then `moon version` again.

## 2. Regenerate docs

```bash
scripts/update-moonbit-docs.py                         # latest async from registry
scripts/update-moonbit-docs.py --async-version 0.22.4  # or pin explicitly
```

The script clones moonbit-docs, moonbitlang/skills and moonbitlang/async
shallowly into a temp dir, resolves `{literalinclude}` directives, copies the
installed core's `pkg.generated.mbti` files, and rewrites `VERSIONS.md`. It is
idempotent. If it warns `missing upstream page`, the docs repo renamed a page:
fix `LANGUAGE_PAGES` / `TOOLCHAIN_PAGES` in the script and rerun.

## 3. Bump the pinned dependency (if async changed)

```bash
moon add moonbitlang/async@<new>   # updates moon.mod import
moon check --target native && moon test --target native
```

Review `git diff docs/moonbit/async/api.md` for API changes affecting
`src/host` (the only async consumer). Fix the host, never the core.

## 4. Review the diff and record learnings

```bash
git diff --stat docs/moonbit
git diff docs/moonbit/language docs/moonbit/agent-guide | less
```

- Language or tooling changes that matter to us (new syntax, deprecations,
  renamed core APIs, `moon.pkg` DSL changes) go into the "Gotchas and
  learnings" section of `.claude/skills/moonbit/SKILL.md`, dated.
- Run `moon check --target all` for `src/core/**`: deprecation warnings after an
  upgrade are the cheapest signal of churn. Fix them in the same commit.
- If a decision in `docs/design/` is affected (e.g. async gains a backend),
  append to `docs/design/decisions.md`.

## 5. Commit

One commit: `docs(moonbit): refresh vendored docs (moonc vX, async vY)`, with
any fixes the upgrade forced. Push only when `scripts/check.sh` is green.
