# bitsql

A memory-only SQL Server emulator in MoonBit that real `tedious` clients reach
over TDS, so CI no longer needs the `mssql/server` container. Faithfulness is
the top priority: a false green is worse than an explicit "not supported" error.

## Start here

- Design: `docs/design/README.md`. SQL Server behavior references distilled
  from captures: `docs/reference/` (completions, result metadata, sql_variant). Live status and next work:
  `docs/design/roadmap.md`. Amendments: `docs/design/decisions.md`.
- Before writing MoonBit, use skill **moonbit** (vendored docs in
  `docs/moonbit/`, conventions, gotchas).
- Before implementing any SQL Server behavior, use skill **implement-feature**:
  oracle first, then corpus case, then code.
- Before every commit, use skill **knowledge-upkeep**: roadmap ticks, findings,
  traps and decisions travel with the code.

## Skills (`.claude/skills/`)

| Skill | Use for |
| --- | --- |
| moonbit | writing/building/testing MoonBit here |
| moonbit-docs-update | refreshing `docs/moonbit/` and pinned versions when a new toolchain or async release appears |
| implement-feature | the oracle-first workflow for any behavior |
| knowledge-upkeep | where each new learning goes |
| harness | TypeScript tedious harness, corpus, capture against real MSSQL, differential runs |
| tds-protocol | MS-TDS reference with annotated hex examples |
| t-sql | T-SQL language and semantics reference |
| sys | `sys.*` / `INFORMATION_SCHEMA` catalog contracts |
| tedious | client behavior and connection options |

## Hard rules

- `src/core/**` is pure: no async, no FFI, no clock, no randomness. Only
  `src/host` touches the OS. `moon check --target all` must pass for core.
- Unsupported features raise `Emulator: …` errors (50100–50199, severity 16),
  never silent approximations.
- Result metadata comes from the binder, never from row values.
- Expected outputs are captured from real SQL Server, never hand-written.
- Push straight to `main` (no PR flow yet), often, but only when
  `scripts/check.sh` is green locally. No CI yet, on purpose.
- **Shared host:** other agents run msduck servers and MSSQL containers here.
  bitsql uses ports 47300–47399 (emulator 47333, oracle MSSQL 47314, or port 0)
  and docker containers named `bitsql-*`. Never stop containers you didn't start.
- Parallel work: subagents in their own git worktrees on branches; merge to
  main when green.

## Commands

```bash
scripts/check.sh                   # gate before push (moon check/test/fmt/info + harness)
moon test -p mirek/bitsql/core/tds # one package
scripts/update-moonbit-docs.py     # refresh vendored MoonBit docs
```

Reference projects (public domain, same author): msduck (Rust/DuckDB) and
mssqlite (TS/SQLite). What to reuse from them is listed in `docs/reuse/README.md`.
