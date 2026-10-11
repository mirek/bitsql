# Reuse from sibling projects

mssqlite (TypeScript/SQLite) is an earlier SQL Server emulator by the same
author. It is public domain and needs no attribution. Inventories:

- [mssqlite.md](mssqlite.md): TDS/T-SQL packages, differential harness, tedious gotchas
- [mssqlite-todo/](mssqlite-todo/): five briefs on how real SQL Server responses differ (ORDER token, RPC completions, error stream, CAST width, catalog types)

To consult the source, clone it shallowly into a scratch directory, not into
this repo:

```bash
git clone --depth 1 https://github.com/mirek/mssqlite.git "$TMPDIR/mssqlite"
```

## Port checklist (tick when done; keep current)

- [x] Skills: tds-protocol, t-sql, sys, tedious → `.claude/skills/`
- [x] mssqlite divergence briefs → `docs/reuse/mssqlite-todo/`
- [x] Bootstrap corpus of real SQL Server captures, oracle-verified: `harness/corpus/captured/` (1153 cases), `harness/corpus/captured-gaps/` (4495 cases) and `harness/corpus/captured-runs/` (8334 cases)
- [~] TDS byte vectors (mssqlite `token.test.ts`, `prelogin.test.ts`, `requests.test.ts`, `value.test.ts`) → MoonBit tests in `src/core/tds` (PRELOGIN 4.1, scramble, ALL_HEADERS, DONE/ENVCHANGE/RPC 4.8 done; mssqlite value.test.ts per-type vectors pending)
- [ ] Lexer rules from mssqlite `packages/tsql/src/lex.ts` (with spans added)
- [~] Captures as MoonBit test tables in `src/core/types/*_data_test.mbt`:
      float-default-grid (subset), unicode-integer, checked-integer,
      temporal-guid-format (us_english modern + legacy), unicode-collation;
      decimal-division / numeric-* / guid-* / integer-overflow as hand-written asserts
