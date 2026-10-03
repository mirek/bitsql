# Reuse from sibling projects

msduck (Rust/DuckDB) and mssqlite (TypeScript/SQLite) are earlier SQL Server
emulators by the same author. They are public domain and need no attribution.
Inventories:

- [msduck.md](msduck.md): SQL Server reference captures, harness libs, behavior docs, TDS vectors
- [mssqlite.md](mssqlite.md): TDS/T-SQL packages, differential harness, tedious gotchas
- [mssqlite-todo/](mssqlite-todo/): five briefs on how real SQL Server responses differ (ORDER token, RPC completions, error stream, CAST width, catalog types)

To consult the sources, clone them shallowly into a scratch directory, not into
this repo:

```bash
git clone --depth 1 https://github.com/mirek/msduck.git   "$TMPDIR/msduck"
git clone --depth 1 https://github.com/mirek/mssqlite.git "$TMPDIR/mssqlite"
```

## Port checklist (tick when done; keep current)

- [x] Skills: tds-protocol, t-sql, sys, tedious → `.claude/skills/` (from msduck, the newer copies)
- [x] mssqlite divergence briefs → `docs/reuse/mssqlite-todo/`
- [ ] Harness: msduck `scripts/lib/{compatibility,reference,reference-container}.mjs` → `harness/src/`
- [ ] Host CLI contract `--listen 127.0.0.1:0` + stderr `listening on 127.0.0.1:<port>` (msduck `tests/support/client.mjs`)
- [ ] Small `reference/*.json` captures (≤ 1 MB each) → `harness/reference/msduck/` + normalizer to one corpus format
- [ ] TDS byte vectors (msduck `reference_vectors`, mssqlite `token.test.ts`, `prelogin.test.ts`, `requests.test.ts`, `value.test.ts`) → MoonBit tests in `src/core/tds`
- [ ] Lexer rules from mssqlite `packages/tsql/src/lex.ts` (with spans added)
- [ ] msduck `tests/tedious.test.mjs` / `tests/compat/*` cases → harness client tests (selectively)
- [ ] Behavior docs worth keeping in-repo → `docs/reference/` (only when a feature is being implemented; cite the source)
- [ ] Attention design (msduck `docs/attention-*.md`) → session/engine design
