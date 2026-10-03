---
name: harness
description: The bitsql TypeScript/Node test harness (harness/) — starting/stopping the real SQL Server oracle container, writing corpus cases (.sql with @step/@param directives), capturing expected output from the oracle, running the differential `diff` against the emulator and reading the ranked report, `npm test` semantics, port/container rules. Use when adding a corpus case, capturing, running or debugging differential/client tests.
---

# bitsql harness

`harness/` is a plain Node ≥ 24 ESM package (`.mjs`, no build step) that drives
real clients — tedious 20.3.3 and mssql 12.7.2, pinned — against either real
SQL Server (**the oracle**) or the bitsql binary (**the emulator**). Most of
the code is ported from msduck `scripts/lib/{compatibility,reference,reference-container}.mjs`
and `tests/support/client.mjs`.

```bash
cd harness && npm install          # once; scripts/check.sh runs `npm test` when node_modules exists
npm run oracle:start               # start or reuse bitsql-oracle (127.0.0.1:47314), prints version
npm run capture -- traps/x.sql     # oracle → traps/x.expected.json (never overwrites)
npm run diff -- smoke traps        # emulator vs expectations, ranked failure list
npm run diff -- --target oracle smoke   # re-verify expectations (determinism check)
npm test                           # client tests + smoke/allowlist corpus on the emulator
npm run oracle:stop                # remove the container
```

## Rules

- **Never hand-write or hand-edit `*.expected.json`.** They are captured from
  the oracle (`npm run capture`) or imported from msduck captures. If a case
  changes, recapture: `npm run capture -- --force <selector>` (explicit
  selectors are required with `--force`). A case edited after capture shows up
  in `diff` as `stale expectation`.
- **Shared host.** Other agents run msduck servers and MSSQL containers here.
  The oracle container is `bitsql-oracle` (override `BITSQL_ORACLE_NAME`, must
  start with `bitsql-oracle`), bound to `127.0.0.1:47314` (`BITSQL_ORACLE_PORT`).
  The harness only ever removes that container. The emulator listens on port 0.
  Any other fixed port you need: 47340–47349.
- Image: `mcr.microsoft.com/mssql/server:2025-latest@sha256:2b5b5816…d726`
  (SQL Server 17.0.5005.3, pulled locally). msduck's pin `@sha256:86cc6144…a74a`
  (17.0.4065.4) is not on this host; imported msduck expectations were
  re-verified against the local image instead.
- The container is reused between runs (fast). Its random SA password lives
  only in the container env and is read back with `docker inspect`.
  `BITSQL_ORACLE_ADDR=host:port` + `BITSQL_ORACLE_PASSWORD` uses an external
  server instead of docker.
- Node runs with `TZ=UTC` forced (tedious binds Date params in local time).

## Emulator target

- `BITSQL_ADDR=host:port`: connect to a running server (isolation: database).
- `BITSQL_BIN=path`: spawn that binary.
- Default: `moon build --target native` at the repo root, then spawn the newest
  `_build/native/**/host/host.exe` with `--listen 127.0.0.1:0` and read
  `listening on 127.0.0.1:<port>` from stderr (msduck contract).
- Emulator logins use `encrypt:false, trustServerCertificate:true` (no TLS in
  v1); the oracle uses `encrypt:true, trustServerCertificate:true`.

## Isolation

Each case runs alone:

- `database` (oracle; emulator with `BITSQL_ADDR`): `CREATE DATABASE
  [bitsql_case_<random>]`, connect to it, run, `DROP` it.
- `process` (emulator spawned by the harness): a fresh server process per case,
  connected to `master`.

Strings naming the case database (messages, `DB_NAME()` values) are rewritten
to `{db}` so both modes compare. Choose with `--isolation database|process`.
Caveat: in process mode the word `master` is rewritten too.

## Writing a case

Hand-written cases are `harness/corpus/<area>/<name>.sql`:

```sql
-- Leading comment block = description; never sent to the server.
-- @step setup
CREATE TABLE t (id int NOT NULL PRIMARY KEY, n nvarchar(10) NULL);
-- @step batch
INSERT INTO t VALUES (1, N'a');
SELECT id, n FROM t;
-- @step rpc
-- @param @id int = 1
-- @param @out nvarchar(10) output
SELECT @out = n FROM t WHERE id = @id
-- @step proc dbo.some_proc
-- @param @x int = 5
```

- Step kinds: `batch` (SQL batch, `execSqlBatch`), `setup` (a batch whose output
  is not compared), `rpc` (tedious `execSql` → RPC `sp_executesql`, even with no
  params), `proc <name>` (`callProcedure`, RPC by name). Without any `@step`
  the whole file is one batch.
- `@param` values are JSON literals: `1`, `"text"`, `null`, `true`; binary as
  hex strings (`"0a0b"`), dates as ISO strings, bigint as a string. Types:
  `int`, `bigint`, `bit`, `decimal(p,s)`, `nvarchar(n|max)`, `varbinary(n)`,
  `datetime2(n)`, `datetimeoffset(n)`, `uniqueidentifier`, … (`src/types.mjs`).
- Error line numbers count from the first line of the step body.
- All steps share one connection; after the last step a reuse probe runs
  (`SELECT @@TRANCOUNT, XACT_STATE(); SELECT 1`) and is compared too.
- Follow msduck capture conventions: never read the clock, name constraints
  explicitly, express counters relative to a baseline (see
  `traps/rowversion-modification-time.sql`), unique statement text for
  plan-dependent sequences.
- tedious loses DATETIMEOFFSET offsets (UTC `Date`): also select
  `CONVERT(nvarchar(40), x, 127)` when the offset matters.
- Then `npm run capture -- <area>/<name>.sql`, inspect the JSON, and run
  `npm run diff -- --target oracle <area>/<name>.sql` once to prove the case is
  deterministic before committing.

Generated multi-case files are `<name>.cases.json`
(`{source, cases:[{name, steps:[{kind, sql, params?, compare?}]}]}`) with one
`<name>.expected.json` (`{server, cases:{<name>: expected}}`). Select one with
`msduck/raiserror-rpc.cases.json#003`.

## What is captured and compared

Per step (`src/capture-core.mjs`): `sets` (columns: name, tedious type name,
length, precision, scale, raw flags, collation; rows canonicalized —
`{kind:"binary"|"date"|"bigint"|"missing"}` wrappers), `done`
(`{kind, rowCount, more}`), `errors` / `info` (`{number, state, class,
lineNumber, message}`), `returnStatus`, `rowCount` (request callback),
`outputs` (RETURNVALUE), `tokens` (DONE-family tokens with `curCmd` and status
bits, msduck layout) and `stream` (compact token sequence, ROW runs
collapsed — catches ORDER, RETURNSTATUS/RETURNVALUE order, INFO placement).
Only keys present in an expectation are compared (imported msduck captures
lack `outputs`/`stream`; some are metadata-only without `rows`).

## Reading the diff report

`npm run diff` prints failures grouped by the kind of their first difference,
largest group first, and writes `harness/out/report.json`
(`totals`, `groups[{kind,count,cases}]`, `failures[{id,kind,path,actual,expected}]`,
`passed`). Kinds:

- `unsupported: Emulator: …` — the step raised an explicit 50100–50199 error.
- `unexpected error N` — emulator raised an error the oracle did not.
- a JSON path with indices as `*`, e.g. `sets/*/columns/*/type`, `done/*/more`,
  `errors/*/number`, `sets/length`, `info/length`.
- `reuse …` — the connection state after the case differs.
- `connect`, `transport`, `isolation`, `stale expectation`.

The top group is usually the next thing to implement (`implement-feature`).
`diff` exits 1 when anything fails.

## `npm test`

`src/test.mjs` probes the emulator first. If it cannot be built, spawned or
logged into, it prints `SKIP …` and exits 0 (so `scripts/check.sh` stays green)
— unless `BITSQL_REQUIRE=1`. Otherwise it runs `node --test test/*.test.mjs`:
client tests (tedious login, tedious `SELECT 1`, mssql pool `SELECT 1`) plus
every `corpus/smoke` case and the selectors in `harness/allowlist.txt`. A test
whose emulator output contains an `Emulator:` error is **skipped** (unless
`BITSQL_REQUIRE=1`); any other divergence **fails**. Add cases to
`allowlist.txt` once `npm run diff -- <selector>` passes, so they cannot
regress.

## msduck import

`npm run import:msduck -- --from "$TMPDIR/msduck" --force` regenerates
`corpus/msduck/` from msduck `reference/*.json` files ≤ 1 MB in the clean
`{results:[{query, reference, tokens?}]}` layout. Mode heuristics: `*-rpc.json`
and `raiserror-failure-counter.json` are RPC; entries with `value` are RPC with
`@s nvarchar`; `parameters` (sp_prepare) entries are skipped. Every imported
case is re-run on the local oracle and kept only if reproduced exactly;
`corpus/msduck/_import.json` lists counts and rejections. Each file keeps
`source: "msduck/reference/<file>"`.

## Findings

- 2026-10-03: Local oracle is 17.0.5005.3; 1153 of 1158 importable msduck
  entries (captured on 17.0.4065.4) reproduce exactly. Rejected: 3
  `unicode-rpc-bindings` (msduck declared a different nvarchar length than
  tedious infers), 1 `nocount-completions-rpc` return status, 1
  `output-typed-stages` message text.
- 2026-10-03: CREATE DATABASE costs ~0.4 s on the oracle; a full msduck
  verification (1158 cases, concurrency 6) takes ~6.5 min. A process-isolated
  emulator run of the whole corpus takes ~2.5 s.
- 2026-10-03: mssql's default pool validation runs `SELECT 1;` via RPC on every
  acquire; tests use `validateConnection: 'socket'` (see tedious skill).
