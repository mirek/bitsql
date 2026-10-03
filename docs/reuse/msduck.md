# msduck reuse inventory

github.com/mirek/msduck: a Rust emulator over DuckDB. Public domain, same
author. Inventoried 2026-10-03 at "Capture exhaustive native CP1252 conversion
projections (#908)". Paths are relative to that repo.

## reference/*.json: SQL Server ground truth (most valuable)

- 231 files (577 MB), all from `mcr.microsoft.com/mssql/server:2025-latest@sha256:86cc6144…a74a`
  (17.0.4065.4 RTM-CU7), server collation `SQL_Latin1_General_CP1_CI_AS`, `TZ=UTC`, login `sa`,
  fresh database per capture, usually run twice with identical results.
- Cleanest layout (~90 files): `{image, version, results: [{query, reference, tokens?}]}` where
  `reference = {sets: [{columns: [{name, type, length, precision, scale, flags, collation}], rows}],
  done: [{kind, rowCount, more}], errors: [{number, state, class, lineNumber, message}], info, returnStatus, rowCount}`.
  Column `type` is the tedious type name; `flags` is the raw COLMETADATA flags word.
- Values are canonicalized: `{kind:"bigint"|"binary"|"date"|"number"|"missing", value}`.
- About 15 layouts by era (`runs`, `containers`, `cases/steps`, `setup/readback/after`). All reduce to
  an ordered (setup, sql) list plus a capture; a ~200-line normalizer can unify them.
- Some include decoded tokens (curCmd, status) and **raw TDS packet hex**: `attention*`, `order-token*`,
  `tvp-*`, `bulk-load-wire`, `for-xml-wire`, `login-database-error`, `session-reset-skiptran`.
- ~20 files over 4 MB are exhaustive grids (TRANSLATE, float, temporal/GUID format, AT TIME ZONE history):
  sample them, don't vendor them.
- Topic groups: errors/completions/control flow (~28), transactions/session (~14), attention (3), wire (~13),
  collation/unicode/character (~50), numeric/decimal (~25), date/time (~25), identity/rowversion/sequence (~12),
  DML/OUTPUT/MERGE (~25), catalog/DDL (~13), JSON/XML (~11), workload `gaps-*` (20).
- Capture conventions (`docs/reference-captures.md`): never read the clock, name constraints explicitly,
  avoid WHILE loops, unique statement text per plan-dependent sequence, Node at UTC.

## Harness code

- `scripts/lib/compatibility.mjs`: `capture` (tedious events, `useColumnNames:false`), `canonical`,
  `differences` (JSON-pointer diff), `runCase` (setup → query → reuse probe → cleanup).
- `scripts/lib/reference.mjs`: `isolatedReference` (fresh `…_audit_<uuid>` DB), `capturePrepared`,
  bounded `assertSameCapture` / `describeFirstDifference`, `writeNewFixture` (never overwrite).
- `scripts/lib/reference-container.mjs`: pinned-digest oracle container lifecycle (random SA password,
  loopback random port, readiness poll ≤180 s, removes only its own container).
- `tests/support/client.mjs`: spawns the server with `--listen 127.0.0.1:0` and reads
  `listening on 127.0.0.1:(\d+)` from stderr. **bitsql's host adopts the same contract**, so
  `tests/tedious.test.mjs` (401 tests) and `tests/compat/*.test.mjs` (~150) can run nearly unchanged.

## Behavior docs worth reading (docs/)

- Metadata: `result-metadata.md`, `reference-comparison.md` (first live diff: 0/273 matched, all metadata),
  `decimal-wire.md` (DECIMAL advertises length 17; payload 5/9/13/17), `order-token.md`, `case-types.md`,
  `declare.md`, `result-names.md`.
- Errors and completions: `control-completions.md` (IF/WHILE → uncounted DONE cmd 0xC0; TRY/CATCH cmds 349/350/351),
  `error-continuation.md`, `transaction-recovery.md` (doomed, 3998), `raiserror.md`, `throw.md`, `try-catch.md`,
  `nocount.md`, `savepoint.md`.
- Attention: `attention-reference.md` (24-case matrix), `attention-design.md`, `request-lifecycle.md`.
- Wire: `tds-gap-inventory.md` (protocol roadmap), `tls.md`, `login-database-error.md`, `session-reset*.md`,
  `prepared-rpc.md`, `return-value-codec.md`, `*-rpc.md` (date, time, numeric, guid, character).
- Strings and collation: `unicode-collation.md` (140 comparisons), `datalength.md`, `len.md`, `trim.md`.
- Dates: `datetime2.md`, `datetimeoffset.md`, `dateformat.md`, `dateadd.md`, `datediff.md`, `datepart.md`.
- Numbers: `decimal-division.md`, `decimal-avg.md`, `numeric-literals.md`, `integer-conversion.md`, `sum.md`.
- Identity: `identity.md`, `identity-insert-*-reference.md`, `rowversion-reference.md`, `sequence-reference.md`.
- `workload-gaps.md`: the 20 areas a real tedious application needed.
- Skip msduck-internal docs: architecture, agent-work, github/parallel workflow, `*-plan`, `*-adapter`, `native-*`.

## TDS codec (crates/msduck-tds)

- Byte vectors in `src/lib.rs` `mod reference_vectors`: MS-TDS 4.1 PRELOGIN request/response,
  the encryption matrix, LOGIN7 scramble of `p@ssw0rd!`, ALL_HEADERS batch.
- `tests/return_value.rs` (18 vectors), `tests/order.rs`, `tests/for_xml.rs`, `tests/request_lifecycle.rs`
  assert against live packet captures.
- Login response order: ENVCHANGE 1 (database), 2 (language), 4 (packet size), 7 (collation `09 04 d0 00 34`),
  LOGINACK, DONE. No FEATUREEXTACK.

## Lessons recorded

1. Metadata dominates diffs: literal `1` and `@@TRANCOUNT` are fixed `Int` with flags 32, while `XACT_STATE()` is
   `IntN(2)` with flags 33. Infer nullability and width statically.
2. Extra or missing empty result sets around caught errors shift the whole comparison, so diff full event sequences.
3. Trailing spaces, MONEY formatting, MONEY division truncates and multiplication rounds.
4. Statement vs transaction failure, XACT_ABORT and doomed (3998) need real statement-level undo, which DuckDB
   could not provide. bitsql's persistent storage makes this natural.
5. tedious quirks: `sp_prepare` completes via the `prepared` event; `request.error` is never cleared;
   `procReturnStatusValue` leaks between requests; bound DATETIMEOFFSET/Date use the client TZ (force UTC);
   `encrypt:false` sends **NOT_SUP** (answer 2); `node:assert` on large captures can OOM (use `isDeepStrictEqual`
   with a bounded diff).
6. SQL Server caches plans by exact text: give plan-dependent sequences unique SQL.
7. Attention must be readable while executing; finish the original response, then send a separate DONE_ATTN.
8. "Decoded OK" ≠ "supported": keep codec coverage and semantic coverage separate.
