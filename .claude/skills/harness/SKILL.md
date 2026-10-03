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
npm run allowlist:sync             # after a full `npm run diff`: allowlist every newly passing case
npm run oracle:stop                # remove the container
npm run parse-diff                 # parser vs SQL Server syntax errors on every captured batch (no server needed)
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
- Steps run on connection 1; after the last step a reuse probe runs there
  (`SELECT @@TRANCOUNT, XACT_STATE(); SELECT 1`) and is compared too.
- Multi-connection cases (locking, deadlocks; corpus `locking/`): `-- @step
  batch conn=2` runs on connection 2 (opened on first use). `async` sends the
  step and continues after 500 ms without waiting (it may block on a lock);
  `-- @step await conn=2` waits for it, and its result is recorded at the
  async step's position. Pending steps are also awaited before that
  connection's next step and at the end. "Process ID n" in messages is
  normalized to `{spid}`. SQL Server's deadlock monitor takes up to ~5 s, so
  deadlock captures are slow.
- `-- @step tm begin [READ_COMMITTED|SERIALIZABLE|SNAPSHOT|…] [name]`, `tm
  commit [name]`, `tm rollback [name]`, `tm save name`: TDS transaction
  manager requests, as tedious `beginTransaction` and mssql `Transaction`
  send them (corpus `tm/`).
- Table-valued parameters: `-- @param @ids table = {"schema":"dbo","name":
  "IdList","columns":[{"name":"id","type":"int"}],"rows":[[1],[2]]}` (tedious
  TYPES.TVP; cells decode like scalar parameter values of the column type).
- `-- @mask sets/0/rows/*/3` inside a step replaces the captured values at
  that path (`*` = every index) with `"{masked}"` on every target: for
  values that read the clock or a spid (sp_help's Created_datetime, sp_who's
  spid). Masks are part of the case hash.
- Client flows that are not corpus-shaped (mssql pools, PreparedStatement,
  bulk load) live in `harness/test/*.test.mjs`; pin their expectations to a
  capture made with the same calls against the oracle (see
  `test/mssql-workflow.test.mjs`).
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

`test/parse.test.mjs` runs the parser over every captured (compared or
hand-written setup) batch in the whole corpus, no server needed. Replayed run
prefixes are skipped (they are checked in their own case). Disagreements
listed in `harness/parse-known.txt` (seeded with the msduck layout import's
226: JSON_OBJECTAGG `k:v`, ALTER DATABASE, JSON_ARRAYAGG ORDER BY, DBCC,
ALTER INDEX … DISABLE, …) are tolerated; new ones fail. Delete lines
as the parser catches up (the test prints the ones that now agree).

## msduck import

`npm run import:msduck -- --from "$TMPDIR/msduck" --force` regenerates
`corpus/msduck/` from msduck `reference/*.json` files ≤ 1 MB in the clean
`{results:[{query, reference, tokens?}]}` layout. Mode heuristics: `*-rpc.json`
and `raiserror-failure-counter.json` are RPC; entries with `value` are RPC with
`@s nvarchar`; `parameters` (sp_prepare) entries are skipped. Every imported
case is re-run on the local oracle and kept only if reproduced exactly;
`corpus/msduck/_import.json` lists counts and rejections. Each file keeps
`source: "msduck/reference/<file>"`.

## msduck layout import (gaps-* and other sequential captures)

```bash
npm run import:msduck-layouts -- --from "$TMPDIR/msduck" --oracles 5 --stop-oracles   # all adapters
npm run import:msduck-layouts -- --from "$TMPDIR/msduck" --only savepoint,gaps-merge --oracles 5
npm run import:msduck-layouts -- --only gaps-keys --dry-run --report /tmp/r.json      # verify, write nothing
npm run import:msduck-layouts -- --list                                                # adapters
```

- Regenerates `corpus/msduck-gaps/` (`gaps-*.json`) and `corpus/msduck-runs/`
  (everything else not in the clean layout). `--only` rewrites just those
  files and merges their stats into `_import.json` (per file: entries,
  cases, imported, `skipped` reasons, `rejected` reasons, rejected ids with
  the first msduck/oracle difference).
- Adapters live in `src/msduck-layouts/*.mjs`, one function per msduck file
  (`(doc, ctx) => Run[]`, shape in `project.mjs`). They read the matching
  `msduck/scripts/capture-<file>.mjs` semantics: connection, request kind
  (batch / `rpc` / `proc` with typed params), what was recorded.
- **Sequential runs** (one connection, state carries over): every entry
  becomes its own case `<file>#NNN-<slug>`; all earlier entries of the run
  replay as uncompared setup. The setup is stored once per file in the
  cases.json `runs` table and referenced as `{run, prefix}`
  (`corpus.mjs expandSteps`); the case hash covers the expanded steps.
  Runs marked `independent` have no prefix.
- Unrepresentable entries (transaction-manager requests, prepared handles,
  second connections, reconnects, session reset, attention, bulk load, TVPs)
  are skipped by reason, and the rest of their run with them (its state
  would differ) unless marked `stateless`.
- Verification: each case runs on the oracle; msduck's recorded result is
  compared with a *projection* of the harness capture (only what msduck
  recorded, in its shape); if equal the case runs a second time and the full
  harness capture must reproduce (determinism). The stored expectation is the
  oracle's full harness capture (`toExpected`), not msduck's partial one.
  Login/request timeouts are retried, never counted as rejections.
- `--oracles N` spreads verification over dedicated containers
  `bitsql-oracle-import-1..N` on 47340+ (CREATE DATABASE serializes inside one
  server; one oracle does ~2 cases/s). `--stop-oracles` removes them.

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

## Emulator test isolation (for app test suites)

`EXEC emulator.snapshot 'name'` captures every database (plus identity
counters, @@DBTS and procedures). `EXEC emulator.restore 'name'` restores it
in O(1). Use it after seeding instead of re-running migrations per test.
Start the host with `--database NAME` so the app's database exists at login
(SQL Server rejects logins to unknown databases with 4060/18456).
- 2026-10-03: `harness/gen/functions.mjs` generates `corpus/functions/*.cases.json`
  (one small SELECT per case; `!`-prefixed entries are raw batches). After
  editing it, regenerate and recapture the touched file with
  `npm run capture -- --force functions/<file>.cases.json` (case names are
  index-based, so delete the file's expected.json first when inserting cases
  mid-list). tedious drops sub-millisecond digits of datetime2/time values:
  add `CAST(x AS nvarchar(40))` columns when they matter.

- 2026-10-03: when the shared `bitsql-oracle` is saturated (other agents'
  bulk captures; logins time out after 15 s), start a private oracle:
  `BITSQL_ORACLE_NAME=bitsql-oracle-tz BITSQL_ORACLE_PORT=47345 npm run
  oracle:start` and pass the same env to `capture`/`diff --target oracle`.
  Remove it with `npm run oracle:stop` under the same env when done.
- 2026-10-03: `harness/gen/timezone.mjs` generates
  `corpus/timezone/at-time-zone.cases.json`; `harness/src/dump-timezones.mjs`
  dumps SQL Server's time zone behaviour for `scripts/gen-timezones.py`
  (docs/reference/at-time-zone.md). Cases reading the clock
  (sys.time_zone_info) compare only clock-independent facts.
- 2026-10-03: `harness/gen/datestrings.mjs` generates
  `corpus/datestrings/*.cases.json` (~3,600 one-SELECT cases: string × type,
  ISDATE, implicit conversions, CONVERT styles). Capturing them takes about
  an hour on the shared oracle (CREATE DATABASE per case dominates); for a
  quick oracle-vs-emulator loop run the SQL of single-batch cases on one
  connection to each server instead and compare rows/errors.
- 2026-10-03: msduck capture layouts (import-msduck-layouts): 154 non-clean
  files, 13875 entries (plus ~16k grid entries sampled out) → 12885 cases →
  12829 kept (4495 gaps, 8334 others); 56 rejected (43 msduck/oracle value
  differences, 13 nondeterministic: generated constraint names). Lessons: (1) msduck's capture scripts,
  not the fixtures, hold part of the SQL (applock batches, gaps-functions,
  identifiers, json_string setup, missing RPC params) — adapters evaluate the
  script's literal sections with `node:vm`. (2) Fixtures name the database in
  many ways: `msduck_audit_<hex>`, `<fresh-database>`, `<database>`, `<db>`,
  `msduck_audit_<database>`, fixed names (`gaps_constraints`,
  `msduck_catalog_reference`), or `master` (unicode-storage,
  windows-1252-best-fit, aggregate-warning-boundaries ran in master) — all
  map to `{db}`. (3) Recorded fields bitsql cannot observe (`procName`,
  `serverName`, column `userType`/`udtInfo`, DONE_INXACT status, raw
  COLMETADATA hex, the raw row count of an uncounted DONE, which SQL Server
  sends as 1 under NOCOUNT) are dropped from the projection, not rejected.
  (4) -0 floats survive only where msduck kept `bits`. (5) Server-version
  probes differ (msduck 17.0.4065.4 / some on 16.0.4236.2) and are skipped.
  (6) Cost: a run of n entries costs n²/2 replayed steps; adapters mark runs
  `independent` or replay only state-changing earlier entries. One oracle
  verifies ~2 cases/s (CREATE DATABASE serializes); `--oracles 5` did the
  full import (2 runs per case) in ~50 min on a busy host.
- 2026-10-03: Under heavy shared-host load the oracle drops logins (15 s
  connect timeout) and requests (30 s); the layout importer retries those
  and never counts them as rejections. Port 47345 is used by another
  agent's `bitsql-oracle-tz`; extra import oracles use 47340–47344.
- 2026-10-03: `harness/gen/xml.mjs` generates `corpus/xml/*.cases.json`
  (FOR XML, the xml type and its methods; one batch per case, `setup`
  steps for tables). Template strings hold T-SQL literals: double the
  single quotes inside `N'...'`. Recapture one case with
  `npm run capture -- --force "xml/<file>.cases.json#<name>"`.
