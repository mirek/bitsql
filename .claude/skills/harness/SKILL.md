---
name: harness
description: The bitsql TypeScript/Node test harness (harness/) — starting/stopping the real SQL Server oracle container, writing corpus cases (.sql with @step/@param directives), capturing expected output from the oracle, running the differential `diff` against the emulator and reading the ranked report, `npm test` semantics, port/container rules, and the ORM compatibility suite (harness/orm: knex, Sequelize, TypeORM, Prisma against oracle and emulator). Use when adding a corpus case, capturing, running or debugging differential/client/ORM tests.
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
npm run probe -- out/x.sql oracle  # run a scratch .sql case, print columns/rows/errors/tokens (no expectation)
npm run bench [-- 20000 80000]     # release-build timings of grouping/subquery/DML shapes (BENCH_ONLY=regexp, BITSQL_BIN)
npm run bench:compare              # mirek/bitsql:<moon.mod version> container vs mssql/server container (README tables; --only, --starts, --json, --from FILE re-renders, BITSQL_IMAGE)
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
- Emulator and oracle logins both use `encrypt:true,
  trustServerCertificate:true` (bitsql has TLS since 2026-10-04;
  `test/tls.test.mjs` covers encrypt true/false and login-only TLS).

## Isolation

Each case runs alone:

- `database` (oracle; emulator with `BITSQL_ADDR`): `CREATE DATABASE
  [bitsql_case_<random>]`, connect to it, run, `DROP` it.
- `process` (emulator spawned by the harness): a fresh server process per case;
  the case runs in a `bitsql_case_<random>` database created in it (since
  2026-10-04; before, it ran in `master`).

Strings naming the case database (messages, `DB_NAME()` values) are rewritten
to `{db}` so both modes compare. Choose with `--isolation database|process`.


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
  `varbinary('max')` passes tedious the *string* `'max'` as the length,
  as knex does: tedious 20.3.3 then sends a malformed PLP value (4002).
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
226: ALTER DATABASE, DBCC, ALTER INDEX … DISABLE, …; the JSON aggregate
entries were removed 2026-10-04) are tolerated; new ones fail. Delete lines
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

## ORM compatibility suite (`harness/orm`)

```bash
cd harness && npm install                 # ../src helpers import tedious from here
cd orm && npm install                     # knex, sequelize, typeorm, prisma (+ schema engine binary)
npm run oracle:start                      # (in harness/) bitsql-oracle on 47314
npm test                                  # all four workloads, oracle vs emulator, exit 1 on new divergences
npm test -- knex typeorm                  # selected workloads
npm test -- --only emulator prisma        # one target, print the trace (ORM_VERBOSE=1: values + SQL)
ORM_PROGRESS=1 ORM_DEBUG=1 npm test -- sequelize   # step progress, error stacks
```

- Own `package.json` (pinned: knex 3.3.0, sequelize 6.37.8, typeorm 1.1.1,
  prisma/@prisma/client/@prisma/adapter-mssql 7.10.0, tedious 20.3.3, mssql
  12.7.2). Not in `scripts/check.sh` (heavy installs, needs the oracle).
- Targets: `lib/targets.mjs` reuses `../src/oracle.mjs` and
  `../src/emulator.mjs` (`BITSQL_ADDR`, `BITSQL_BIN`, or `moon build` +
  spawn). One emulator process serves all workloads. Each workload gets a
  fresh database `bitsql_orm_<name>` on both targets (Prisma also
  `bitsql_orm_prisma_push`); oracle databases are dropped afterwards.
- `workloads/<orm>.mjs` export `(target, trace) => …` and wrap every
  observable operation in `trace.step(name, fn)`; loggers feed
  `trace.logSql`. `lib/trace.mjs` normalizes clock values, generated
  constraint suffixes, the database name, Sequelize transaction ids and
  savepoint names; `lib/compare.mjs` reports the first difference per step.
  `out/report.json` holds both traces.
- `known.json` (`"<workload>/<step>": "reason"`) lists accepted
  divergences (printed, not failing). Every other divergence is a bug:
  reduce it to a corpus case under `corpus/orm/`, capture, fix.
- Prisma: `prisma/schema.prisma` (+ `schema.v1.prisma` that produced the
  two committed migrations via `prisma migrate diff`), `prisma.config.mjs`
  reads `DATABASE_URL`; the client is generated into `prisma/generated`
  (git-ignored) on first run. The CLI's schema engine is tiberius; the
  URL is the same for both targets (`encrypt=true`; `encrypt=false`, i.e.
  login-only TLS, works too). The CLI refuses `db push
  --accept-data-loss` under an AI agent; the workload never passes it.
- Scratch probes for ORM questions live in `harness/orm/out/` (ignored):
  a tedious script that logs every `execSql`/`execSqlBatch` text is the
  quickest way to see what an ORM really sends.

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
- 2026-10-04: in a hand-written `.sql` case every comment line starting
  with `-- @` is a directive, so a description line like `-- @@NESTLEVEL …`
  silently became a step (corpus `proc/nest-levels`). Quick oracle loop
  before writing a case: put the steps in the corpus `.sql` format and run
  them with `runCase(await oracleTarget(), { steps: parseSqlCase(text) })`
  from a scratch script under `harness/out/` (not committed); one fresh
  database per run, no expectation written.
- 2026-10-04: `harness/gen/conversion.mjs` generates `corpus/conversion/*`
  (CONVERT styles incl. Hijri, input styles, numeric storage bytes,
  text/ntext/image, COMPRESS/DECOMPRESS, CHECKSUM, CURSOR_STATUS,
  COLUMNS_UPDATED; 461 cases, ~8 min to capture). In `.cases.json` files use
  `{kind: 'batch', compare: false}` for setup steps (`setup` is only a `.sql`
  directive). A quick way to learn a rule before writing cases: a throwaway
  node script calling `src/capture-core.mjs` `capture()` over many small
  batches on one oracle connection (no CREATE DATABASE per case).
- 2026-10-04: a reusable oracle/emulator probe for learning rules before
  writing cases: put batches separated by `----` lines in a file and run a
  scratch `harness/out/probe.mjs` that calls `capture()` on one connection
  per target (oracle in a `bitsql_probe` database, a spawned emulator) and
  prints rows/errors (and the token stream with STREAM=1), flagging
  differences. ~60 JSON probes ran in under a minute. `npm run
  allowlist:sync` appends every passing case of the last report, also ones
  that passed before; parse-known.txt entries that now agree are listed by
  `node --test test/parse.test.mjs` and must be deleted.
- 2026-10-04: `harness/gen/functions2.mjs` generates `corpus/functions2/*`
  (FORMAT/PARSE in ~50 cultures, .NET format edge cases, ORDER BY keys,
  GREATEST/CONCAT typing, offset window functions; 292 cases, ~4 min to
  capture). `harness/gen/cultures.mjs` rebuilds
  `src/core/exec/culture_data.mbt` from the oracle's FORMAT output (run
  `moon fmt` afterwards); add a culture to its list and regenerate rather
  than editing the table. For a quick oracle loop without CREATE DATABASE
  per case, a scratch script that runs one batch per line on one oracle
  connection (`capture()` from src/capture-core.mjs) answers dozens of
  "what does SQL Server print" questions in seconds.
- 2026-10-04: `harness/gen/settings.mjs` generates `corpus/settings/
  dateformat.cases.json` and `language.cases.json` (SET DATEFORMAT ×
  shapes × types with TRY_CAST, 17 languages); hand-written
  `settings/*.sql` cover ALTER DATABASE, database collation, RCSI,
  snapshot isolation and UTF-8. (Corrected 2026-10-04 tail5: the
  process-mode traps noted here, a case database that was master and
  "master" rewritten to `{db}`, are gone; process isolation now runs each
  case in its own database. The existing cases that CREATE and USE their
  own database or keep "Changed database context to 'master'" in setup
  steps still pass.)
  `ALTER DATABASE … SET READ_COMMITTED_SNAPSHOT ON` needs the database to
  itself: run it before opening `conn=2`. Quick probes without
  an expectation: `npm run probe -- file.sql [oracle|emulator|both]` prints
  columns, rows, errors and the token stream per step (keep the .sql under
  `harness/out/`, which is not committed).
- 2026-10-04: `npm run bench` (harness/bench/bench.mjs) builds the release
  binary and times ~20 query and DML shapes over N-row tables (default
  20000; pass several sizes to check n log n scaling). Run it before and
  after executor changes: quadratic paths show up as 16x per 4x rows. The
  release build takes ~2 min; `BITSQL_BIN=` reuses a binary, `BENCH_ONLY=`
  selects queries by name.
- 2026-10-04 (ORM suite): system procedures written in T-SQL inside SQL
  Server (sp_addextendedproperty) emit internal DONEINPROC/ENVCHANGE
  tokens and row counts; corpus cases mask them with `-- @mask tokens`,
  `stream`, `done`, `rowCount` per step and still compare results and
  errors. A case that needs a second database creates it with a fixed name
  in a setup step and drops it at the end (orm/object-ids).
  `npm run probe` rejects `@param` names that are not identifiers (`@0`).
- 2026-10-04 (long tail round 4): `harness/src/dump-system-catalog.mjs`
  dumps sys.system_objects / system_columns for `scripts/gen-sysviews.py`.
  In process isolation the case database is master, so captures that read
  another database as `master` (gaps-catalog #107/#115/#117, sys-databases
  #003) or print `master` fail only there; check them with `BITSQL_ADDR`
  (database isolation) before chasing them. Useful scratch helpers (not
  committed, recreate under `harness/out/`): a script that prints a failing
  case's step SQL with the report's first difference, and one that prints
  the expanded steps of a case with its expected errors and token stream;
  `npm run probe -- out/x.sql both` remains the fastest way to learn a rule.
  Parallel forks on one oracle worked fine (captures are per case database).
- 2026-10-04 (tail5): process isolation now creates a case database in the
  spawned server instead of running in `master`. The six cases that failed
  only there (gaps-catalog #107/#115/#117, sys-databases #003,
  tedious-compat-gaps #013/#014) plus three DATABASEPROPERTYEX ones
  (gaps-conversion #1305/#1309/#1320: master is SIMPLE, not full-text)
  pass; no case regressed; the full run takes ~20 s longer (~1m50s). The
  emulator's master was not wrong: those captures read `master` as
  *another* database. Corrected: the 2026-10-04 settings note that "the
  emulator's case database is master" no longer holds. Scratch helpers
  worth recreating under `harness/out/`: `stepdiff.mjs <selector>` (runs a
  case on a spawned emulator, prints every differing step with its SQL, not
  just the first difference) and a one-connection probe that runs `----`
  separated batches on the oracle in a fresh database. Tool trap: the agent
  tool layer turns `\uXXXX` sequences in tool input into the characters
  themselves (also inside heredocs); build JSON escapes in SQL with
  `REPLACE(N'~u0041', N'~', NCHAR(92))`.
- 2026-10-04 (tail5 fork A): `npm run bench` gained two non-ASCII ORDER BY
  queries (`N'é' + v` shared prefix, `NCHAR(224 + id % 30) + v`). After the
  collation fast path, ORDER BY / GROUP BY / DISTINCT over 20k ASCII strings
  take ~25-55 ms (integers ~12-28 ms; before ~350 ms); strings first
  differing at an accented character still take the element-array path
  (~120 ms at 20k).
- 2026-10-04 (corpus `backup/`): `{db}` normalization only replaces the
  case database name when no word character follows, so `<db>_log` (a
  logical log file name, `…_log.ldf`) stays raw and differs per run; name
  derived objects `DB_NAME() + N'-copy'` (normalizes to `{db}-copy`) and
  mask values/messages that contain `<db>_log`. Server-wide state on the
  shared oracle (msdb backup history, backup files under
  /var/opt/mssql/data) accumulates across runs: derive paths and names from
  DB_NAME() and filter history by them. A second session's
  `EXEC('USE x; WAITFOR …')` as an `async` step is a usable way to have a
  session inside another database.

- 2026-10-04 (ATTENTION): request cancellation is not corpus-shaped (the
  corpus runner cannot cancel); `test/attention.test.mjs` covers it and runs
  against the oracle with `ATTENTION_ORACLE=1` to re-verify its pinned
  expectations. For exact token streams of flows the capture layer cannot
  see (tedious discards a cancelled request's response unparsed), a scratch
  TCP proxy between tedious (`encrypt:false`, i.e. login-only TLS, so
  everything after LOGIN7 is plaintext) and the server that logs each TDS
  packet as hex works on both targets; it can also inject raw packets (an
  idle ATTENTION `06 01 00 08 00 00 01 00`) and swallow their replies.
- 2026-10-04 (msduck re-import): to find msduck captures newer than the
  last import, clone msduck shallowly into the scratchpad and list
  `git log --since=<last import> --name-only -- reference`, then compare
  `reference/*.json` against the `source` fields of `corpus/msduck*/`.
  Re-import changed files with `--only a,b,c --oracles 3` (~1,200 cases in
  ~12 min); a jump in rejections means the fixture's setup changed (msduck
  #889 recaptured gaps-unicode-predicates under the server default instead
  of BIN2: the adapter now takes `doc.collation`). Remove the
  `bitsql-oracle-import-*` containers afterwards. `harness/src/
  dump-collation-weights.mjs` regenerates
  `src/core/types/collation_weights_data.mbt` (ignorable code units,
  accent ranks) from the oracle.
- 2026-10-05: per-request profiling without the oracle:
  `WORKLOAD=requests REPS=3 scripts/profile.sh` (or `node bench/profile.mjs`
  with `BITSQL_BIN`) runs compare.mjs's request workload (SELECT 1,
  parameterized INSERT / point SELECT, transactions, report) and prints
  wall time plus server CPU from `/proc/<pid>/schedstat`; the wall time is
  mostly tedious and TLS, so compare CPU. `report.py --focus FUNC` keeps
  only samples with FUNC on the stack (e.g. `rpc__executesql`).
  Add `POINTS_ONLY=1` to stop after the point-read batches (setup, SELECT 1
  and inserts still run), excluding the transaction/report workloads from
  a longer point-read profile.
- 2026-10-05: `npm run bench:compare` (harness/bench/compare.mjs) produces the
  README benchmark tables. It runs containers `bitsql-bench-bitsql`
  (47340) and `bitsql-bench-mssql` (47341), removes them at the end, and
  shares its query shapes with `npm run bench` through `bench/shapes.mjs`.
  Memory and CPU come from the container's cgroup v2 files
  (`/sys/fs/cgroup/system.slice/docker-<id>.scope`, systemd driver).
  Download size comes from `docker manifest inspect --verbose`, so it reads
  "n/a" for a locally built `BITSQL_IMAGE`. The default image tag follows
  moon.mod, so bump the version only after pushing, or pass `BITSQL_IMAGE`.
  Results are stable to a few percent between runs. SQL Server 2025 starts
  in ~2.6 s here once its image is cached.
- 2026-10-05: **every release with material performance changes refreshes
  the README benchmark tables** (knowledge-upkeep). Order: bump moon.mod and
  `exec/version.mbt`, `scripts/docker-publish.sh` (local images + smoke),
  `BITSQL_IMAGE=mirek/bitsql:X.Y.Z-amd64 npm run bench:compare`, paste the
  tables and the version/date sentence into README, commit, then
  `scripts/docker-publish.sh --push`. A local image has no download size
  ("n/a"); fill it in from `docker manifest inspect --verbose` after the
  push, or re-run `bench:compare` with the default tag. Pure bug-fix
  releases keep the previous tables and their version label.
- 2026-10-05: an alternative release workflow runs the full client suite once
  against the actual cross-built amd64 binary: build local images with
  `SKIP_SMOKE=1 scripts/docker-publish.sh`, then run
  `BITSQL_BIN=$PWD/_build/xarch/amd64/bitsql scripts/check.sh` and the release
  script's arm64 quick-smoke selection under `bitsql-qemu` (smoke plus
  allowlisted analytic/conversion/statistical cases). After the gate passes,
  commit, stamp the image revision label with that commit, and assert the
  image's `RootFS.Layers` are identical before/after the metadata-only change.
  Benchmark, then push these exact tested images and create the version,
  minor and latest manifest lists; verify each remote manifest's platforms
  and child digests. Refresh README from the measurements, including registry
  layer sizes after pushing. This avoids rebuilding or re-testing the same
  release binaries solely to publish them (used for 0.1.9 and 0.1.10).

- 2026-10-06: `bench:compare` query/DML shape timings are medians of five
  runs after one warm-up; JSON preserves `shapes.samplesMs` and `repetitions`.
  Every execution checks SQL errors and aborts the comparison on failure.
  DML shapes roll back, preserving data for repeated samples. Earlier
  comparison JSON without these fields contains one timed sample per shape;
  `--from` keeps rendering it with the original interpretation.

- 2026-10-06: `bench/profile.mjs` now fails on SQL errors in setup, warm-up
  and every timed execution, matching the comparison runner. Failed queries
  must never appear as fast measurements.

- 2026-10-06: a benchmark Docker launch can fail binding 47340 despite a
  preceding LISTEN-only check. Inspect all TCP states with `ss -tanp` for
  47340/47341 and Docker container names. Retry only after the old process is
  confirmed terminal and the ports/names are free; never stop someone else's
  service. A launch failure before timings does not yield benchmark results.

- 2026-10-06: confirmed the post-gate port conflict on 0.1.17: `ss -tanp`
  showed TIME-WAIT at local 127.0.0.1:47340 (peer was an ephemeral emulator
  port). Waiting until that state disappeared allowed the comparison to start.
  LISTEN-only checks miss this; do not remove another process to clear it.

- 2026-10-06: `bench:compare` now stores five 1000-query point-SELECT batches
  (`pointReadsSamplesMs`, `pointReadsRepetitions`) after one full warm-up and
  reports their median. This read-only workload was near parity and its prior
  single batch varied between runs. Old JSON without samples retains the old
  table label; do not compare the two methodologies as an isolated code gain.

- 2026-10-06: Node 24 processes show Linux `comm` as `MainThread` here
  (confirmed during the 0.1.20 gate), so filtering `ps` by `comm == node`
  misses live harness/benchmark work. Inspect the executable in `args` too
  (`node` or an absolute path ending `/node`) before timing on the shared host.

- 2026-10-06: point-read batches also retain `pointReadsCpuSamplesMs` and
  their median `pointReadsCpuMs` from container cgroup counters. Reads occur
  outside each timed batch; the wall-time methodology is unchanged. These
  are total container CPU deltas, including background work, not exclusive
  query CPU. Use them to investigate latency outliers without replacing the
  recorded wall-time samples or selecting a favorable rerun.

### Expected request disconnects (2026-10-06)

JSON case steps may set `captureDisconnect: true` for an oracle-proven
ECONNRESET. This preserves the partial response and client error; it does not
waive timeouts or other transport failures. A primary-connection reset permits
its subsequent EINVALIDSTATE reuse result; a secondary reset does not. See
`test/capture-disconnect.test.mjs` and `sql2025/json-wide-corruption-access`.
There is no SQL-file directive for this opt-in.

- 2026-10-07: `node gen/capture-embeddings.mjs --verify` verifies the controlled
  HTTPS embedding fixture against a uniquely named disposable oracle; `--force`
  recaptures it. It never enables REST on the shared oracle. The fixture records
  outgoing HTTP payloads as well as SQL metadata/results/errors; generated pure
  tests come from `scripts/gen-embedding-tests.py`. Certificate setup, automatic
  Docker port changes after restart, and the explicitly fatal malformed-options
  case are documented in `docs/reference/external-models.md`.


### Native architecture release policy (2026-10-07)

User instruction: each host builds, tests and benchmarks its own architecture
only (amd64 on amd64, ARM64 on ARM64). This supersedes the historical cross-build
and QEMU workflows above. Do not use `FULL_ARM64_SMOKE`, foreign runtime downloads
or emulated SQL Server containers by default. Use checked-in oracle captures or
a remote oracle when a native oracle is unavailable. `scripts/docker-publish.sh`
builds/tests/publishes the native architecture and preserves other already
published architectures of that same version. Coordinate manifest writes across
hosts. Publishing the verified native architecture is sufficient for this host's
release; another host can add its architecture after its native checks pass.

- 2026-10-08: allowlist selectors are corpus paths, not case IDs: a SQL file
  needs its `.sql` suffix (`query-store/options.sql`). A bare case ID silently
  selects nothing. Check new case names in the gate log; the Query Store
  collector gate caught nine missing suffixes despite focused diffs passing.

- 2026-10-08: the user explicitly requires amd64+arm64 for the Query Store
  scaffold release, with no local ARM64 runtime test. Use
  scripts/docker-publish.sh --push --multiarch for this authorized exception:
  same generated C and matched MoonBit runtime, ARM64 cross compiler, no QEMU,
  native amd64 client suite. Default releases remain native-only. Verify both
  manifest entries and same-version/revision labels; do not claim ARM64 runtime
  validation from a successful cross-build.
