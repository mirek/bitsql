---
name: tedious
description: "Using the tedious MSSQL client against bitsql (and real SQL Server) — connection options that matter (TLS, port, useColumnNames), Request API and events (row, infoMessage on the connection, done vs doneInProc), how tedious maps operations to the wire (sp_executesql RPC, sp_prepare handles, transaction manager), and e2e testing patterns. Use when writing server e2e tests or debugging client interop."
---

> **Provenance.** Reference content ported from the sibling projects msduck and
> mssqlite (same author, public domain). Notes that mention `packages/*`,
> `mssqlite`, `msduck`, SQLite or DuckDB describe *those* implementations. They
> are field notes verified against SQL Server there, not claims about bitsql.
> Real SQL Server captures remain the authority (docs/design/verification.md).

## bitsql implementation

`harness/` (TypeScript). bitsql speaks TLS like SQL Server (2026-10-04): connect with tedious's default `encrypt: true` plus `trustServerCertificate: true` (built-in self-signed certificate), or `encrypt: false` (PRELOGIN NOT_SUP, plaintext).

## bitsql findings (keep current)

Append dated, one-paragraph findings here whenever bitsql work confirms,
corrects or adds to this reference: wire bytes, client behavior or SQL Server
semantics observed in captures. Correct wrong inherited notes in place and
mention the correction here.

- 2026-10-03: `mssql` (12.7.2) `ConnectionPool` validates every acquired
  connection by default with `SELECT 1;` sent through `execSql` (an RPC
  `sp_executesql`, not a batch). If that request fails, `pool.connect()` and
  every query retry until `connectionTimeout`/tarn's timeout ("operation timed
  out for an unknown reason") instead of surfacing the server error. Against a
  partial emulator use `validateConnection: 'socket'` (or `false`).
- 2026-10-03: tedious decodes DATETIMEOFFSET into a UTC JS `Date` (plus
  `nanosecondsDelta`); the offset itself is not observable through the value.
  Corpus cases that care about offsets must also select
  `CONVERT(nvarchar(40), x, 127)`. `uniqueidentifier` arrives as an upper-case
  string; bigint/COUNT_BIG/DATEDIFF_BIG as decimal strings.
- 2026-10-03: `connection.debug.token` is invoked for every parsed token even
  without debug listeners, so overriding it per request (as the harness does)
  records the full token stream, DONE `curCmd` and status bits included,
  without enabling packet logging (which would capture LOGIN7 secrets).
- 2026-10-03: `execSql` without parameters still sends RPC `sp_executesql`
  (completions: DONEINPROC per statement, RETURNSTATUS 0, final DONEPROC with
  curCmd 224); only `execSqlBatch` sends a SQL batch. `callProcedure` with an
  output param yields RETURNSTATUS before RETURNVALUE before DONEPROC.
- 2026-10-04 (harness/orm, ORM compatibility suite): knex 3.3.0 binds
  every Buffer as VarBinary with `length: 'max'` (a string); tedious
  20.3.3 compares it numerically, declares varbinary(max) but writes the
  PLP value without its terminator, so real SQL Server answers 4002 and
  Buffer inserts through knex fail (`db.raw('0x..')` works). An empty
  Buffer bound by tedious without a length declares max length 0: 8016.
  Transaction isolation levels set by tedious's beginTransaction (knex
  `isolationLevel`, TypeORM, Sequelize) stay on the pooled connection
  after commit (a later snapshot-level transaction leaks 3952 into the
  next query). Prisma 7: the client needs no engine binary (query compiler
  + `@prisma/adapter-mssql` over `mssql`/tedious, `encrypt:false` works);
  the CLI's schema engine is Rust/tiberius, whose `encrypt=false` still
  means login-only TLS (PRELOGIN ENCRYPT_OFF), supported since 2026-10-04.
  Prisma's CLI refuses `db push --accept-data-loss` when it detects an AI
  agent (Claude Code); plain `db push` on an empty database works.
  Sequelize 6 mssql: `sync({ alter: true })` emits `ALTER COLUMN ...
  DEFAULT` for columns with a defaultValue, 156 on real SQL Server too;
  `bulkCreate({ ignoreDuplicates })` is rejected client-side. knex mssql
  has no onConflict() and no createSchema(). TypeORM rejects an unawaited
  promise from startTransaction on a destroyed DataSource (crashes Node
  without an unhandledRejection handler).
- 2026-10-04: TLS (test/tls.test.mjs, same results on the oracle). tedious
  20.3.3 caps TLS at 1.2 itself (message-io.js startTls) and sends one
  PRELOGIN message per handshake flight, expecting exactly one PRELOGIN
  message back; SQL Server's replies are type 0x12, EOM, packet id 0.
  `encrypt: true` → PRELOGIN ON, server ON, negotiated
  ECDHE-RSA-AES128-GCM-SHA256 / TLSv1.2 on both targets;
  `dm_exec_connections.encrypt_option` is TRUE only for full TLS (FALSE for
  NOT_SUP and for login-only). `encrypt: 'strict'` (TDS 8) fails against
  the oracle image ("socket disconnected before secure TLS connection").

# tedious Client Against mssqlite

`tedious` is the pure-JS MSSQL driver used for end-to-end tests
(`packages/server/src/server.test.ts`). It exercises the full stack the
same way real applications do.

- 2026-10-03 (harness test/mssql-tvp.test.mjs): mssql `request.input('ids',
  table)` with an `sql.Table('dbo.IdList')` (or `sql.TVP`) sends TYPES.TVP;
  `execute('dbo.pick')` is an RPC by name, `query()` sp_executesql with the
  declaration `@ids dbo.IdList readonly`. `rowsAffected` of a procedure
  ending in `RETURN (SELECT COUNT(*) FROM @ids)` has two entries (the
  subquery counts). tedious cannot send NULL TVPs through mssql (its
  declaration reads `value.schema`) nor sql_variant TVP columns. Corpus
  steps take TVPs as `-- @param @ids table = {"schema":"dbo","name":
  "IdList","columns":[{"name":"id","type":"int"}],"rows":[[1]]}`.

## Connection options that matter

```ts
new Connection({
  server: '127.0.0.1',
  authentication: { type: 'default', options: { userName: 'sa', password: 'any' } },
  options: {
    port,                        // pick the listener's port; 0 → ephemeral in tests
    encrypt: true,               // tedious default; server needs TLS key + cert
    trustServerCertificate: true,
    database: 'master',
    useColumnNames: true,        // row event gives an object keyed by column name
    connectTimeout: 5000,
    requestTimeout: 5000
  }
})
```

- tedious ≥ 16 defaults to `encrypt: true`. Start mssqlite with
  `tls: { key, cert }`; required encryption is the server default whenever TLS
  is configured. `trustServerCertificate: true` is appropriate only for an
  explicitly trusted self-signed development certificate. For a plaintext
  local server with no TLS configuration, set `encrypt: false`.
- To validate a private CA, set `trustServerCertificate: false` and pass it as
  `cryptoCredentialsDetails: { ca }`. `serverName` must match a certificate
  DNS/IP subject alternative name; Node rejects an IP literal as an SNI name,
  so set a DNS `serverName` even when the TCP target is an IP.
- `connection.connect(callback)` — the callback fires after LOGINACK +
  final DONE. `connection.state.name === 'LoggedIn'` confirms handshake.
- Failed logins surface as `ConnectionError` from the ERROR token. The
  connection callback reports code `ELOGIN`; listen to the connection's
  `errorMessage` event to assert the underlying 18456 token number. Password-
  authenticated mssqlite listeners require `encrypt: true` and required TLS.

## How tedious talks to the server

| tedious call | Wire | mssqlite handling |
|---|---|---|
| `execSql(request)` without params | SQL batch (0x01) | `engine.executeBatchAsync` |
| `execSql(request)` with params | RPC `sp_executesql` (by name) | `engine.executeSqlAsync` |
| `callProcedure(request)` | RPC by procedure name | system/user procedure dispatch, result sets + return status |
| `prepare(request)` / `execute(request, params)` | RPC `sp_prepare` (0xFFFF + id 11) / `sp_execute` (12) | handle map in `server/connection.ts` |
| `beginTransaction/commitTransaction/rollbackTransaction` | Transaction manager (0x0E) types 5/7/8 | engine transactions + ENVCHANGE 8/9/10 |
| `newBulkLoad` + `execBulkLoad` | SQL batch `INSERT BULK`, then Bulk Load (0x07) | incremental decoder + atomic engine loader |
| `cancel()` | Attention (0x06) | DONE with DONE_ATTN |
| `connection.reset()` (tedious 20) | SQL batch (0x01), first packet `RESETCONNECTION` status (0x08) | The copied upstream mssqlite notes called reset a no-op; this is not an msduck or SQL Server behavior claim. |

Tedious 20's `Connection.reset()` sets `resetConnectionOnNextRequest` and sends
`getInitialSql()` through `execSqlBatch`; its packet writer maps the flag to
status bit 0x08. The [msduck SQL Server 2025 capture](../../../docs/session-reset-reference.md)
observes the outgoing Batch message and reset flag, callback, response events,
and follow-up session state, including invalidation of a server prepared handle
(error 8179 on reuse). It does not test `RESETCONNECTIONSKIPTRAN` (0x10).

Tedious 20 does not expose MARS/SMP, so it cannot be the MARS-capable client
ground truth. Use `System.Data.SqlClient` (or `Microsoft.Data.SqlClient`) with
`MultipleActiveResultSets=True` for the external interoperability smoke test.
The repository's `server/mars.test.ts` independently drives exact PRELOGIN,
SMP, and TDS bytes so automated tests do not depend on a .NET installation.

RPC parameter TYPE_INFO is semantically significant, not only a decoder hint:
the server maps it to the scoped variable's T-SQL declaration so mixed-type
predicates and assignments use SQL Server precedence. E2E tests should include
a typed character parameter compared with a numeric expression and assert both
the successful result and error 245 for invalid numeric text. Decimal RPC
parameters cast to integer must use their declared numeric source type so the
engine truncates toward zero; explicit bigint result metadata makes tedious
surface even a small value such as zero as a string.

## Request API and events

```ts
const request = new Request(sql, (error, rowCount) => { ... })
request.addParameter('age', TYPES.Int, 18)   // no @ prefix — tedious adds it
request.on('row', columns => { ... })        // per row
connection.execSql(request)
```

- **`row`** — with `useColumnNames: true`, `columns` is
  `Record<name, { value }>`. Values are decoded per COLMETADATA TYPE_INFO:
  `IntN` → number, `NVarChar` → string, `DateTimeN`/`DateTime2N` → JS
  `Date`, `BitN` → boolean, `FloatN` → number.
  Duplicate labels necessarily overwrite in this object form. Use
  `useColumnNames: false` when labels may repeat; the `row` event then receives
  an ordered column array and mssqlite preserves every positional value.
- **`infoMessage` fires on the Connection, not the Request** — PRINT
  output and other INFO tokens land there. `errorMessage` likewise.
- The request callback's error is an MSSQL-shaped error with `.number`
  (e.g. 208 invalid object, 2627 unique violation) — assert on it.
- Multiple ERROR tokens produce an `AggregateError` whose `.errors` retain
  token order; the Connection's `errorMessage` events interleave with Request
  `row` events, so test mixed failing/successful batches through both streams.
- `done` / `doneInProc` / `doneProc` events mirror the DONE token family;
  counts from tokens carrying DONE_COUNT contribute to the Request callback's
  rowCount. Trigger-body DML can therefore add to the originating count.
  NOCOUNT makes the event argument `undefined` and excludes that completion
  from the callback total; result rows and `@@ROWCOUNT` remain available.
- `execBulkLoad` first sends its generated `INSERT BULK table(columns...)`
  batch and waits for DONE, then streams COLMETADATA, ROW values, and DONE in
  packet type 7. Its callback row count comes from the server's DONE_COUNT.
  `keepNulls`, `checkConstraints`, and `fireTriggers` become INSERT BULK
  options. Cancellation before the stream finishes uses an IGNORE EOM packet
  without a separate Attention; cancellation after send uses Attention.
  Unlike `freebcp -b`, tedious sends one type-7 request for the supplied row
  iterable, so a server-side row failure rolls back that complete request.
- `Request.cancel()` has two wire paths. While the request payload is still
  streaming, tedious terminates it with IGNORE and expects one normal response;
  after EOM it sends Attention, consumes the original request's response, then
  reads a separate response until DONE_ATTN. If the server sends only one
  DONE_ATTN message, the first reader consumes it and SentAttention eventually
  fails with `ETIMEOUT`. A successful cancel callback receives `ECANCEL`.

## Testing patterns

- `packages/differential` uses one `useColumnNames: false` tedious capture
  path against mssqlite and SQL Server 2025. It records every
  `columnMetadata`, ordered row/result set, DONE/DONEINPROC/DONEPROC count,
  stable error fields, transaction state, and a follow-up reuse probe.
  The artifact also records tedious's post-decryption packet headers and
  decoded response-token diagnostics per case. Packet data/payload diagnostics
  stay disabled so LOGIN7 secrets are never persisted.
  Intentional differences must name an exact JSON-pointer path and both values;
  run the container-backed suite only with `pnpm test:differential`.
- Listen on port 0 and read the assigned port
  (`await listen({ port: 0 })`).
- TLS e2e tests use a fixed localhost certificate and exercise tedious with its
  current encryption default, private-CA validation, hostname mismatch,
  plaintext rejection, and the higher-level `mssql` client.
- One shared connection in `beforeAll` keeps tests fast; open a second
  connection inside a test to check session isolation.
- Multiple-database e2e tests should switch only the second connection with
  `USE`, verify DB_NAME()/DB_ID() and local metadata there, then query the same
  object through a three-part name on the still-master first connection.
- Wrap Request in a promise helper collecting rows + rowCount (see
  `server.test.ts`).
- LIKE character-class e2e tests should include literal and typed RPC patterns,
  case folding under the default collation, ESCAPE, and error 506 so SQLite's
  native no-class LIKE cannot leak through one expression source.
- Non-SC UTF-16 tests must inspect JavaScript `length` and `charCodeAt`, not only
  visual output: tedious preserves lone surrogate units decoded from NCHAR,
  SUBSTRING/LEFT/RIGHT/STUFF, and code-unit REVERSE TDS payloads.
- Keep a table variable's declaration and all references in one SQL-batch
  request; a later `execSql` call is a new batch and must receive error 1087.
- TVF result metadata is available even for NULL/empty inputs. Remember that
  tedious surfaces STRING_SPLIT's bigint `ordinal` as a string, while
  GENERATE_SERIES over int literals retains IntN(4) and surfaces numbers.
- APPLY e2e tests should cover both CROSS row elimination and OUTER NULL
  extension; use explicit projected columns for rewritten TOP (1) sources.
- PIVOT/UNPIVOT e2e tests should listen for `columnMetadata` as well as rows:
  all-NULL generated PIVOT columns must retain the aggregate input TYPE_INFO,
  while UNPIVOT's name column is NVARCHAR and its value column keeps the
  common declared input type.
- Advanced-grouping e2e tests must include a real NULL detail row and the
  visually identical subtotal NULL, distinguished by GROUPING(). The latter
  arrives as nullable-family `IntN(1)` metadata and a JavaScript number;
  grouped and aggregate columns retain their declared source-derived widths.
- Integer AVG must arrive as IntN(4) or IntN(8), not SQLite's FloatN result,
  and COUNT_BIG remains IntN(8) even for zero. Tedious exposes both bigint
  aggregate values as strings regardless of their runtime magnitude.
- FOR JSON arrives as one column named
  `JSON_F52E2B61-18A1-11d1-B105-00805F49916B` with NVarChar(max) metadata.
  Test a value larger than 8 KiB so the server's PLP path is exercised;
  tedious still surfaces the completed value as one JavaScript string.
- Bulk-load e2e tests should include an `AsyncIterable` or thousands of rows,
  an nvarchar(max)/varbinary(max) PLP value spanning packets, NULL/default
  handling, a constraint rollback, and cancellation followed by another query
  on the same connection. node-mssql `Table` + `request.bulk` exercises the
  higher-level SqlBulkCopy-style API over the same tedious wire path.
- MARS wire e2e tests should hold a multi-packet reader at its four-packet SMP
  window, prove a sibling SID still completes, then cover a shared transaction,
  sibling SQL error, session-local Attention, connection reuse, and FIN reply.
  Separately run a .NET SqlClient reader plus concurrent command on one
  `MultipleActiveResultSets=True` connection to catch implementation-specific
  sequence/window assumptions.
- Attention e2e tests should cancel a long interpreted loop after EOM, assert
  `ECANCEL` and no row events, verify completed work remains inside an explicit
  transaction, roll it back, then cancel immediately after `execSql` to cover
  IGNORE. Run another query after each path to prove connection reuse.
- User-function e2e tests should cover a scalar declared return type (BIGINT
  arrives as IntN(8) and a string) and an inline TVF used as an ordinary FROM
  source. CREATE FUNCTION definitions must be sent in their own request/batch.
- System-procedure e2e tests should use `Request.callProcedure()` with named
  parameters and collect every `columnMetadata`/`row` group: `sp_help`,
  `sp_helpdb`, and `sp_spaceused` can emit multiple result sets. Procedure names
  and `sys.` aliases are case-insensitive. Test `sp_rename` by querying the
  renamed SQLite object afterward, not only by inspecting its return status.
- Catalog-coverage tests should query `INFORMATION_SCHEMA` and `sys.dm_exec_*`
  through ordinary `execSql`, asserting `columnMetadata` as well as values.
  Open a second tedious connection to prove session rows are server-wide; the
  querying connection should see its own request 0 as `running`/`SELECT`.
- IDENTITY e2e tests should use a non-1 seed/increment, assert generated values
  plus `@@IDENTITY` / `SCOPE_IDENTITY()` / `IDENT_CURRENT`, and verify explicit
  input fails with tedious error number 544. Open a second connection when
  checking session-local IDENTITY_INSERT behavior.
- tedious parameter types worth covering: `TYPES.Int`, `TYPES.BigInt`
  (arrives as string), `TYPES.NVarChar` (PLP when long), `TYPES.Bit`,
  `TYPES.Float`, `TYPES.DateTime` / `TYPES.DateTime2`,
  `TYPES.UniqueIdentifier`, `TYPES.VarBinary`, `TYPES.Numeric`.
- Windows-1252 scalar tests should assert both values (`ASCII('€') = 128`,
  `CHAR(128) = '€'`) and metadata: ASCII is IntN(4), while CHAR is
  nullable VarChar(1), not inferred NVarChar.

## Gotchas discovered

- tedious sends `sp_executesql` by **name**, not by ProcID — handle both.
- RPC OptionFlags is 2 bytes on the wire (the MS-TDS example prose shows
  a single byte but the byte count proves otherwise).
- tedious validates TYPE_INFO strictly: NVARCHAR must carry a 5-byte
  collation; PLP `max` types use the 0xFFFF length marker and 8-byte PLP
  framing in rows.
- BigInt columns (`IntN(8)`) are surfaced by tedious as **strings**.
- LOGIN7 from tedious includes FeatureExt (UTF8 etc.); acking is optional
  — mssqlite skips FEATUREEXTACK and tedious proceeds.
