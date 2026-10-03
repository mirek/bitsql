# mssqlite reuse inventory

github.com/mirek/mssqlite: a TypeScript emulator over SQLite (pnpm monorepo).
Public domain, same author. Inventoried 2026-10-03 at commit "Implement fixed
integer result metadata (#60)" (2026-07-18). Paths are relative to that repo.

## Wire side (packages/bytes, packages/tds, ~4k lines TS)

- `bytes`: immutable `Cursor`, result-typed decoders, LE default and explicit BE
  helpers, `bVarchar`/`usVarchar` (UCS-2 char counts), `bVarbyte`/`usVarbyte`/`lVarbyte`,
  `Ucs2`, `Cp1252` (varchar is Windows-1252, not latin1), `Hex.of` for tests.
- `tds/src`:
  - `packet.ts`, `message.ts`: header `type, status, len(BE16), spid(BE16), packetId, window`; default 4096;
    EOM on last; ids from 1 wrap mod 256; pure `push(state, chunk)` reassembly that rejects
    `length < 8` and a type change before EOM; tracks the IGNORE bit (0x02).
  - `prelogin.ts`: option table `token, BE16 offset, BE16 length`, `0xFF` end; VERSION =
    `u8 major, u8 minor, BE16 build, LE16 subbuild`.
  - `login7.ts`: 36-byte fixed part, 9 offset/count pairs (count = chars); password
    `x ^= 0xA5; swap nibbles`; FeatureExt via a 4-byte pointer when `optionFlags3 & 0x10`.
  - `all-headers.ts`, `sql-batch.ts` (ALL_HEADERS + UCS-2 text, no length prefix),
    `rpc.ts` (`nameLen == 0xFFFF` means ProcID: 10 sp_executesql, 11 prepare, 12 execute,
    13 prepexec, 15 unprepare; OptionFlags u16; param = `bVarchar name, u8 status, TYPE_INFO, value`).
  - `type-info.ts`, `value.ts`, `data-type.ts`: wire families fixed/byteLen/ushortLen/longLen/plp/date/scaled/decimal;
    NULLs: byteLen 0, ushort 0xFFFF, long 0xFFFFFFFF, PLP 8×0xFF; PLP = u64 total (`…FE` unknown) + u32 chunks + 0 terminator.
  - `decimal.ts`, `date-time.ts`, `guid.ts`, `collation.ts`, `sql-variant.ts`.
  - `token/*`: COLMETADATA, ROW, DONE*, ERROR/INFO, LOGINACK, ENVCHANGE (1,2,4,7,8,9,10),
    RETURNSTATUS, RETURNVALUE, FEATUREEXTACK. Missing there: NBCROW output, ORDER (0xA9), SESSIONSTATE.
- `server/src/connection.ts` (`parameterType` ~l.430): TYPE_INFO → T-SQL declaration for RPC params.
- **Byte fixtures to port** (`packages/tds/src/`): `token.test.ts`, `prelogin.test.ts`,
  `requests.test.ts`, `login7.test.ts`, `packet.test.ts`, `value.test.ts`, `codecs.test.ts`,
  `robustness.test.ts` (deterministic hostile-length fuzz).

## Key wire facts (also in the tds-protocol skill)

- LOGINACK: `0xAD len16 | u8 interface=1 | u32 BE tdsVersion 0x74000004 | bVarchar "Microsoft SQL Server" | major minor buildHi buildLo`.
- Default collation SQL_Latin1_General_CP1_CI_AS = `09 04 D0 00 34`. ENVCHANGE collation is a bVarbyte of 5 bytes;
  packet-size ENVCHANGE carries the size as a *string*.
- Login response order used: ENVCHANGE database(new, old) → ENVCHANGE collation → ENVCHANGE language `us_english`
  → LOGINACK (7.4, "Microsoft SQL Server" 15.0.2000) → ENVCHANGE packet size → DONE final. No FEATUREEXTACK needed.
- Attention ack is its *own* message `FD 20 00 00 00 00 00 00 00 00 00 00 00` after the cancelled response's final DONE;
  folding it in makes tedious time out.
- DONE status: more 1, error 2, count 0x10, attn 0x20, srvErr 0x100; curCmd 0xC1 SELECT, 0xC3 DML, 0xE0 DONEPROC.
- Non-null ints use fixed INT1/2/4/8; nullable use INTN. CHAR/NCHAR 0xAF/0xEF vs VARCHAR/NVARCHAR 0xA7/0xE7.
- MS-TDS's COLMETADATA example mislabels 0x20 as nullable; nullable is bit 0.
- PRELOGIN without TLS: client OFF or NOT_SUP → answer NOT_SUP; client ON/REQ → reject. tedious needs
  `encrypt: false, trustServerCertificate: true`.

## Language side (packages/tsql, ~3k lines)

- Hand-written lexer (`lex.ts`) + token-level PEG combinators (`parse/*.ts`), `first` keeps the farthest failure.
- Lexer rules worth copying: `[..]` with `]]`, `".."`, `N'..'`, `''`, nested `/* */`, `--`, `@var`/`@@global`,
  `0x…` binary, raw numeric text, `$action`, `#temp`, longest-first operators incl. `!<`, `!>`, `+=`, `::`.
- `GO` is not grammar. Reserved words are function names only directly before `(`. MERGE needs its `;` (10713).
- AST has **no source spans**, so ERROR_LINE was always 1. bitsql must carry spans from day one.
- Tests: `parse.test.ts` (53 tests), `lex.test.ts`. `packages/tsql/Readme.md` is a feature checklist.
- tedious's post-login SET batch requires permissive generic `SET name ON|OFF|word|expr` handling
  (`parse/statement.ts:172-220`).

## Differential harness (packages/differential, ~700 lines): lift almost as-is

- `docker.ts`: `mcr.microsoft.com/mssql/server:2025-latest` pinned by digest (17.0.4065.4), `TZ=UTC`,
  `-p 127.0.0.1::1433`.
- `run.ts`: waits for login, `CREATE DATABASE … COLLATE SQL_Latin1_General_CP1_CI_AS`, `SET NOCOUNT OFF; SET XACT_ABORT OFF`.
- `client.ts`: `useColumnNames: false`, `rowCollectionOnRequestCompletion: false`, timeouts 5 s/15 s.
- `execute.ts` + `normalize.ts`: Execution = column metadata (name, type.name, dataLength, precision, scale,
  nullable = flags & 1), normalized rows, every done/doneInProc/doneProc `{rowCount, more}`, errors `{number, state, class, lineNumber}`.
- `capture.ts`: setup, query, session probe (`@@TRANCOUNT`, `XACT_STATE()`, `SELECT 1` reuse check), cleanup.
- `compare.ts`: JSON-pointer diff; declared known differences `{path, emulator, sqlServer, reason}`; a declared
  difference that no longer occurs fails the run (no silent widening).
- `trace.ts`: tedious debug packet/token events → token sequence.
- `corpus.ts`, `artifact.ts`, `reproduction.ts`.

## Divergence briefs (copied to docs/reuse/mssqlite-todo/)

1. ORDER token (0xA9) after COLMETADATA for ordered queries.
2. RPC completions: one per statement plus a separate final DONEPROC.
3. Error stream: real source line; COLMETADATA before a runtime error when the schema is known; RETURNSTATUS before
   DONEPROC on RPC error; trailing INFO "statement terminated" after truncation/unique errors.
4. `CAST(x AS VARCHAR)` defaults to width 30; declarations default to 1.
5. sys.* name columns are sysname = nvarchar(128); `max_length` is non-null smallint.

## tedious gotchas

- `sp_executesql` is sent by **name**; accept both name and ProcID. RPC OptionFlags is 2 bytes.
- TYPE_INFO is validated strictly (NVARCHAR needs a 5-byte collation; max types use 0xFFFF + PLP).
- bigint arrives in JS as strings. COUNT_BIG is IntN(8); integer AVG is IntN, not float.
- `infoMessage`/`errorMessage` fire on the Connection. Multiple ERRORs arrive as an `AggregateError`.
- NOCOUNT ON: keep DONE, clear DONE_COUNT, zero count.
- Cancel before EOM: IGNORE bit → one normal DONE, don't execute. After EOM: Attention → finish, then separate DONE_ATTN.
- FOR JSON column name `JSON_F52E2B61-18A1-11d1-B105-00805F49916B`, nvarchar(max) PLP.
- Table variables live one batch (1087 later). CREATE FUNCTION must be alone in its batch. No MARS in tedious 20.
