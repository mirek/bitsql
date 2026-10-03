---
name: implement-feature
description: The bitsql workflow for implementing or fixing any SQL Server behavior (protocol, T-SQL syntax, semantics, catalog, locking) — oracle-first capture against real MSSQL, corpus case, implementation in the right core package, unsupported-feature policy, and the docs/skills to update. Use whenever starting a roadmap item, fixing a harness divergence, or adding a T-SQL feature.
---

# Implementing a SQL Server behavior

Faithfulness beats coverage: a false green is worse than an explicit
"not supported". Follow these steps in order.

## 1. Pick work

- Read `docs/design/roadmap.md` (live status). Prefer what unblocks the gate of
  the current phase, then the top of the harness's ranked failure list, then
  what still pins the target suite to MSSQL.
- Check `.claude/skills/*/SKILL.md` "bitsql findings" and
  `docs/design/fidelity-traps.md` for known traps in the area.
- Look for prior art in sibling projects (`docs/reuse/README.md`): msduck's
  `reference/*.json` may already contain the exact SQL Server output, and its
  `docs/*.md` may describe the semantics.

## 2. Establish ground truth first

- Write the corpus case (`harness/corpus/...`, see skill `harness`) *before*
  the implementation, and capture expected output from real MSSQL
  (`npm run capture` in harness). Never hand-write expected output.
- No docker or MSSQL available? You may implement from a msduck reference
  capture or the t-sql/tds-protocol skills, but mark the case `unverified` and
  add a roadmap item to capture it.

## 3. Implement in the right layer

| Concern | Package |
| --- | --- |
| bytes on the wire | `src/core/tds` |
| text → AST | `src/core/ast` |
| names, types, implicit casts, metadata, dialect choices | `src/core/bind` (+ `Semantics`) |
| evaluation, DML delta consumers, errors | `src/core/exec` |
| values, conversions, decimal/datetime/guid | `src/core/types` |
| tables, indexes, catalog, snapshots | `src/core/store` |
| locks, waits, deadlocks | `src/core/sched` |
| session state, scopes, RPC dispatch | `src/core/session` |
| sockets, timers | `src/host` (should almost never change) |

The executor never branches on dialect. Metadata never depends on row values.
Never let user input drive an aborting operation (huge `repeat`, unchecked
indexing, `unwrap`): an abort kills the server for every session (moonbit
skill gotchas).

## 4. Unsupported or partial?

Raise the emulator error (50100–50199, severity 16, message
`Emulator: <feature> is not supported`) instead of approximating. Allocate a
number in `src/core/types/emulator_errors.mbt` (create it if missing). Add a
corpus case asserting the error, so the gap stays visible.

## 5. Test

- Unit tests in the package (`moon test -p ...`).
- Engine-level test if the behavior crosses packages.
- Harness/differential run for anything observable by a client.
- `scripts/check.sh` must be green before pushing (main stays green).

## 6. Update knowledge (same commit)

Use skill `knowledge-upkeep`: tick the roadmap, add traps, add "bitsql findings"
to the relevant skill, and log design deviations in `docs/design/decisions.md`.
