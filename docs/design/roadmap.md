# Roadmap and live status

Each phase ends at a gate the harness can check; the first value arrives at
gate 3 when migrations run green. **Keep the checkboxes current**: tick an item
in the same commit that makes it true, and add newly discovered work as
unchecked items. The ranked failure list from the differential harness
overrides the order inside a phase.

Legend: `[x]` done and tested, `[~]` partially done (say what is missing), `[ ]` not started.

## Phase 0: project setup

- [x] MoonBit module, vendored docs with rerunnable update script
- [x] Design split into topic docs, project skills
- [x] Reuse inventory of msduck / mssqlite (`docs/reuse/`)
- [ ] CI workflow — deferred on purpose (too much churn); local `scripts/check.sh` is the gate

## Phase 1: capture and harness

- [x] `harness/` package: tedious 20.3.3 + mssql 12.7.2, connect helper (emulator via BITSQL_BIN/BITSQL_ADDR, oracle container `bitsql-oracle` on 47314); `npm test` skips cleanly until the emulator runs SQL
- [x] Corpus format (`.sql` with `-- @step`/`-- @param`, `.cases.json`) + `capture` (real MSSQL → `.expected.json`); smoke (18) and traps (17) captured on 17.0.5005.3
- [x] `diff` runner: run corpus against emulator, compare, ranked failure list (`harness/out/report.json`)
- [~] Import msduck `reference/*.json` captures that fit the corpus format: 1153 cases from the 76 clean-layout files ≤ 1 MB, each verified on the local oracle. Missing: the ~123 files in other layouts, the 24 prepared-protocol entries (needs a `prepared` step kind), and samples of the 31 files > 1 MB
- [ ] **Blocked on access:** capture one CI run of the target app with tedious
      debug logging; grep its SQL for `OBJECT_ID|COL_LENGTH|sys\.|INFORMATION_SCHEMA|UPDLOCK|HOLDLOCK|SERIALIZABLE`.
      Needs the app repo path or a capture from its owner.
- Gate: corpus checked in; harness runs it against real MSSQL.

## Phase 2: TDS and the core boundary

- [x] Packet framing (reassembly across reads, split by negotiated size, EOM)
- [x] PRELOGIN request decode / response encode (`ENCRYPT_NOT_SUP`)
- [x] LOGIN7 decode; LOGINACK, ENVCHANGE (database, packet size, collation), INFO, DONE
- [x] SQLBatch decode (ALL_HEADERS, UTF-16LE text)
- [~] Token encoders: COLMETADATA, ROW, ORDER, DONE/DONEPROC/DONEINPROC, ERROR, INFO, RETURNSTATUS, RETURNVALUE done; NBCROW missing (only needed if captures show SQL Server using it for our shapes)
- [x] RPC decode: proc id / name, params with TYPE_INFO and values (incl. PLP); dispatch of sp_executesql/sp_prepexec is in session work
- [~] ATTENTION: acknowledged as a separate DONE_ATTN message; real cancellation needs time-sliced execution
- [~] Engine::handle + native host (TcpServer, queue, `--listen`, `listening on` contract), `--record` event log and `replay` tool done; timers missing
- [x] tedious 20.3.3 connects (encrypt:false), login SET batch accepted; other SQL → `Emulator:` error via stub executor
- [x] Stub executor replaced by parser + binder + executor (core/bind, core/exec, core/session)
- **Gate met 2026-10-03**: `tedious` runs `SELECT 1` and a parameterized `sp_executesql`, identical to MSSQL in the harness (smoke/select-1, smoke/rpc-*).

## Phase 3: parser coverage, DDL and catalog

- [x] Lexer (bracket/quoted identifiers, N'' strings, comments incl. nested `/* */`, `GO` separators):
  `core/lex` (`lex`, `split_go_batches`), spans with line/col on every token.
- [~] Expression parser, SELECT, DML, DDL, procedural statements: `core/parse` covers the
  v1 list (expressions with T-SQL precedence, SELECT/CTE/set ops/APPLY/OPENJSON/FOR JSON,
  INSERT/UPDATE/DELETE/MERGE/OUTPUT, CREATE/ALTER/DROP TABLE/INDEX/VIEW/PROC/FUNCTION/
  TRIGGER/SCHEMA/TYPE/SEQUENCE, GRANT/DENY/REVOKE, DECLARE/SET/IF/WHILE/TRY/THROW/
  RAISERROR/EXEC/cursors/transactions, tedious's login SET batch). Missing: PIVOT/UNPIVOT,
  WITH XMLNAMESPACES, GROUP BY ALL / WITH ROLLUP, TABLESAMPLE, FOR SYSTEM_TIME, legacy
  `FROM t (NOLOCK)` hints, `.WRITE`, xml/CLR method calls (`x.value(...)` parses as a
  qualified call), `type::Method()`, DDL triggers (`ON DATABASE`), CREATE/ALTER DATABASE,
  ALTER INDEX, ENABLE/DISABLE TRIGGER statements, `EXECUTE AS` statement, `EXEC ... AT`,
  legacy `RAISERROR n 'msg'`, `SET @cursor = CURSOR ...`, JSON_OBJECT.
  Error numbers 102/156/111/319/10713 follow captures where available; trailing statements
  after CREATE VIEW/FUNCTION and the THROW-after-unterminated rule are unverified guesses.
- [~] Parse differential over the corpus: 1707/1707 batches agree with SQL Server (`npm run parse-diff`); `parsecheck FILE...` ready for the target codebase (needs app repo)
- [~] Types: int family, bit, decimal, (n)varchar, datetime2, datetimeoffset, uniqueidentifier, rowversion
      (`src/core/types`: values, precedence/result types, CAST/CONVERT, checked arithmetic,
      comparison and collations, emulator error table. Missing: `harness/corpus/traps` cases
      for the new type traps and oracle captures for the unverified choices listed in the
      t-sql skill findings (no MSSQL was run for this work), non-ISO date strings / DATEFORMAT / LANGUAGE, CONVERT styles beyond
      0/1/2/3-12/20-25/100-112/120/121/126/127, float style 3, decimal ↔ binary, CP1252
      best-fit, money styles beyond 0/1/2, collations other than Latin1_General/SQL_Latin1)
- [~] Store: `PMap` + `core/store` Db (tables, rows by rowid, unique/non-unique index maps, modules, schemas); views/procs/functions as stored modules not wired yet
- [~] DDL execution: CREATE/DROP TABLE (columns, NULL/NOT NULL, IDENTITY, DEFAULT, computed, PK/UNIQUE/CHECK/FK incl. self-reference), temp tables, table variables, TRUNCATE, CREATE/DROP PROCEDURE (session-level). Missing: ALTER TABLE, CREATE INDEX, views, functions, triggers, schemas
- [ ] Virtual `sys.*` / `INFORMATION_SCHEMA` views the scripts touch; `OBJECT_ID`, `COL_LENGTH`, …
- Gate: all migration scripts run green.

## Phase 4: DML and access paths

- [~] Binder + IR (core/bind, core/ir) with captured metadata rules; Semantics record not extracted yet (T-SQL rules inline)
- [~] Executor: scan, filter, project, nested-loop joins (inner/left/right/full/cross), sort, limit, distinct, union all, values. Missing: aggregate/GROUP BY, subqueries, CTEs, APPLY, window functions
- [~] INSERT (VALUES/SELECT/DEFAULT VALUES, defaults, identity, IDENTITY_INSERT, computed, rowversion), UPDATE (compound SET, DEFAULT), DELETE, statement-level rollback. Missing: OUTPUT, UPDATE/DELETE FROM, TOP, MERGE, triggers (Delta consumers)
- [~] Constraints: NOT NULL 515, PK/UNIQUE 2627, unique index 2601, CHECK 547, FK 547 both directions, truncation 2628, identity not rolled back. Missing: cascades, NOCHECK, messages verified against captures
- [ ] Index seeks on sargable predicates
- Gate: first tests move to the emulator allowlist.

## Phase 5: procedural

- [ ] Scope stack, variables, temp tables, table variables
- [~] Procs (session-level registry): RPC by name and EXEC in batches, params with defaults, OUTPUT, return status. Missing: store modules/sys visibility (catalog agent), nested scope rules for temp tables
- [x] Dynamic SQL (`sp_executesql` via RPC and in batches, `EXEC(@sql)`), DONEINPROC/DONEPROC framing, return status = last @@ERROR
- [~] TRY/CATCH with captured completion tokens, THROW/rethrow, RAISERROR (formatting, SETERROR, 2787), @@ERROR per statement, statement-level rollback. Missing: doomed transactions (XACT_STATE -1, 3998), XACT_ABORT effects verified, 266 trancount mismatch
- [x] Cursors: STATIC snapshot, FAST_FORWARD/default read from a snapshot with an Emulator error if base tables change while open; LOCAL/GLOBAL; FETCH NEXT/PRIOR/FIRST/LAST/ABSOLUTE/RELATIVE; @@FETCH_STATUS, @@CURSOR_ROWS; captured CurCmd codes. DYNAMIC/KEYSET/FOR UPDATE raise Emulator errors
- [ ] Triggers (AFTER, INSTEAD OF)
- [~] JSON: `core/json` implements JSON_VALUE, JSON_QUERY, ISJSON (types, depth 13606), OPENJSON default schema, path parsing (lax/strict, keys, quoted keys, indexes), passing all msduck boundary captures. Missing: OPENJSON WITH schema, wildcards/advanced accessors, JSON_MODIFY, FOR JSON, binder wiring
- Gate: all non-concurrency tests on the emulator.

## Phase 6: concurrency

- [~] Transactions over persistent roots (BEGIN/COMMIT/ROLLBACK, ENVCHANGE 8/9/10, statement-level rollback); concurrent writers raise 50107 until the lock manager is wired
- [~] Interval lock manager (`core/sched`: S/U/X, key intervals, whole-table fallback, FIFO + conversion priority, statement/transaction durations) done; LockSpec from hints/isolation not wired yet
- [~] Wait-for graph + cycle detection + cheapest-victim choice in `core/sched`; engine parking/1205 not wired yet. Victim tie-break (requester) unverified against SQL Server
- [ ] Deterministic mode + replay
- [ ] `emulator.snapshot` / `emulator.restore`
- Gate: the MSSQL CI job is removed; nightly cross-check remains.

## Phase 7: packaging

- [ ] Static-ish native binary, minimal container image, size/RAM check (< 100 MB idle)

## Limiting factor

For first value: phases 2–3, the protocol plus full parser coverage, because no
test can run until `tedious` connects and migrations succeed. For the whole
project: the breadth of transaction and error semantics in phases 5–6.

## Risks

| Risk | Mitigation |
| --- | --- |
| False greens from subtle semantic gaps | Differential harness; nightly cross-check; explicit errors for unsupported features |
| MoonBit toolchain churn | Pre-1.0 language: async churn confined to the ~150-line host, the core uses no async; versions pinned, docs vendored with a rerunnable script |
| Scope creep from rarely used features | Harness failure ranking drives priorities |
| Long tail delays the RAM payoff | Allowlist routing gives speed gains early |
| Lock behavior diverges due to access paths | Seek on sargable predicates; conservative `WholeTable` fallback |
| Target app suite not available in this repo | Build the corpus from msduck captures + traps first; capture the app as soon as access is given |
