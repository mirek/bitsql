---
name: tds-protocol
description: "Comprehensive TDS (Tabular Data Stream) protocol reference for implementing MSSQL clients and servers. Covers packet framing, message types, token streams, data types, login, prelogin, SQL batch, RPC, transactions, error handling, and wire format details. Use when implementing TDS protocol handling, debugging wire-level issues, or understanding MSSQL communication."
---

> **Provenance.** Reference content ported from the sibling projects msduck and
> mssqlite (same author, public domain). Notes that mention `packages/*`,
> `mssqlite`, `msduck`, SQLite or DuckDB describe *those* implementations. They
> are field notes verified against SQL Server there, not claims about bitsql.
> Real SQL Server captures remain the authority (docs/design/verification.md).

## bitsql implementation

`src/core/tds` (codec: framing, PRELOGIN, LOGIN7, tokens, TYPE_INFO, values). Byte-exact tests live in `src/core/tds/*_test.mbt` and should cite the example section in [examples.md](examples.md) they come from.

## bitsql findings (keep current)

Append dated, one-paragraph findings here whenever bitsql work confirms,
corrects or adds to this reference: wire bytes, client behavior or SQL Server
semantics observed in captures. Correct wrong inherited notes in place and
mention the correction here.

- _(none yet)_


# TDS Protocol Reference

Complete reference for the Tabular Data Stream (TDS) protocol used by Microsoft SQL Server. Based on the MS-TDS open specification and SQL Server documentation.

Source: [MS-TDS Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/b46a581a-39de-4745-b076-ec4dbb7d13ec)

MARS transport source: [MC-SMP Specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/MC-SMP/04c8edde-371d-4af5-bb33-a39b3948f0af)

## Reference Files

- [packet-framing.md](packet-framing.md) — Protocol overview, TDS versions, connection flow, packet header format
- [prelogin-login.md](prelogin-login.md) — PreLogin message, Login7 message, password scrambling, FeatureExt
- [tokens.md](tokens.md) — Token stream overview, COLMETADATA, ROW/NBCROW, DONE, ENVCHANGE, ERROR/INFO, LOGINACK, RETURNSTATUS, RETURNVALUE, FEATUREEXTACK, SESSIONSTATE, and other tokens
- [data-types.md](data-types.md) — TYPE_INFO, fixed/variable-length types, PLP, COLLATION, datetime encoding, decimal, money, GUID, sql_variant, vector, UDT, XML, TVP
- [messages.md](messages.md) — ALL_HEADERS, SQL Batch, RPC Request, Transaction Manager, Bulk Load, Federated Auth, SSPI, Attention
- [response-patterns.md](response-patterns.md) — Server response patterns (login, query, SP, error, transactions), variable-length data stream definitions
- [state-machines-and-notes.md](state-machines-and-notes.md) — Client/server state machines, TLS/SSL encryption, routing, MARS, implementation notes, common pitfalls
- [examples.md](examples.md) — Protocol examples with annotated hex dumps: PreLogin, Login7, SQL Batch, RPC, Attention, SSPI, Bulk Load, Transaction Manager, TVP, SparseColumn, FeatureExt, SESSIONRECOVERY, AZURESQLSUPPORT

## Inherited notes: @mssqlite/tds implementation in mssqlite (not bitsql)

This spec is implemented in [`packages/tds`](../../../packages/tds)
(tests assert exact bytes from [examples.md](examples.md)):

| Spec area | Module |
|---|---|
| Packet header, splitting, reassembly | `packet.ts`, `message.ts` |
| MARS Session Multiplex Protocol framing | `smp.ts` |
| PreLogin request/response and encryption negotiation | `prelogin.ts` |
| Login7 + password descrambling + FeatureExt | `login7.ts` |
| SQL-login authentication + generic 18456 failure | `server/authentication.ts`, `server/connection.ts` |
| ALL_HEADERS, SQL batch, RPC, transaction manager | `all-headers.ts`, `sql-batch.ts`, `rpc.ts`, `transaction-manager.ts` |
| BulkLoadBCP COLMETADATA/ROW/DONE stream | `bulk-load.ts` |
| TYPE_INFO + TYPE_VARBYTE values incl. PLP | `type-info.ts`, `value.ts` |
| Collation, GUID, decimal, date/time wire formats | `collation.ts`, `guid.ts`, `decimal.ts`, `date-time.ts` |
| Server tokens (COLMETADATA, ROW, DONE*, ERROR/INFO, LOGINACK, ENVCHANGE, RETURNSTATUS, RETURNVALUE, FEATUREEXTACK) | `token/*` |

The live differential packet/token trace records an open ORDER-token gap for
ordered result sets; see
[`todo/order-token-fidelity.md`](../../../todo/order-token-fidelity.md).

### Notes discovered implementing

- mssqlite implements the full-session TDS 7.x encryption matrix, not
  login-only encryption. TLS handshake records remain PRELOGIN-wrapped until
  the final server record has drained; Node's server-side `secure` event can
  fire just before that write, so switching to raw records in the event handler
  loses the client at the framing boundary.
- MARS is negotiated only when the client requests PRELOGIN MARS=1. LOGIN7 and
  its response remain ordinary TDS; SMP begins with client SYN afterward.
  SMP's 16-byte header is entirely little-endian after signature `0x53`; the
  first DATA sequence is 1, SYN is 0, and FIN reuses the last DATA sequence.
  Each DATA frame carries exactly one complete TDS packet. The server starts
  with four-packet credit, advertises `receiveSequence + 4`, acknowledges near
  the window edge, rejects backward windows/out-of-order DATA, and schedules
  eligible response packets round-robin across SIDs.
- Password authentication is applied only after full LOGIN7 decode and before
  session/database allocation. Required TLS protects the descrambled secret;
  uniform 18456/state 1 failures close the connection after ERROR + DONE_ERROR.
- Bulk load packet type 7 is selected for fragment streaming in `Message.push`:
  complete packets bypass whole-message reassembly, while `BulkLoad.push`
  retains at most one incomplete token (capped at 16 MiB), emits complete rows,
  rejects NBCROW and hostile lengths, and requires a final DONE exactly at EOM
  by default. Server compatibility mode accepts FreeTDS/freebcp's observed
  row-boundary EOM without a client DONE; incomplete rows still fail.
  An IGNORE-terminated request receives a normal completion because clients
  canceling before message completion do not necessarily send Attention.
- Attention after request EOM is a distinct path. Finish/discard the active
  request response first, then send the acknowledgement as a separate tabular
  response containing exactly `FD 20 00 00 00 00 00 00 00 00 00 00 00`
  (DONE + DONE_ATTN, command/count zero). `tedious` is already reading the
  original response when it enters SentAttention and waits for the next message;
  combining the acknowledgement with the original response causes its cancel
  timer to expire.
- **RPC OptionFlags is 2 bytes** (USHORT). The example 4.8 prose lists a
  single `00` byte, but the packet length arithmetic (47 total) only
  works with two flag bytes.
- The COLMETADATA example labels flags `0x0020` as "Nullable"; per the
  flag table `0x0020` is `fComputed` and nullable is bit 0 — trust the
  bit table, clients don't validate these strictly.
- tedious addresses `sp_executesql` by **name**, not ProcID — servers
  must accept both `NameLenProcID` forms.
- RPC parameter TYPE_INFO must survive decoding as the engine variable's
  declared T-SQL type. Using only the decoded JS value loses data-type
  precedence (for example VarChar `'2'` compared with Int `2`) and can silently
  inherit SQLite's mixed-storage-class comparison.
- Clients tolerate a missing FEATUREEXTACK even when Login7 carried
  FeatureExt options.
- money is genuinely split high-int32-then-low-uint32 — not a plain
  little-endian int64 (see §14).
- Time-only strings need parsing support in date/time codecs — `time(n)`
  values have no date part; MSSQL treats the implied date as 1900-01-01.
- DATETIMEOFFSETN carries UTC time/date followed by the original signed offset,
  not local time/date. Its 3/4/5-byte time rounds at the TYPE_INFO scale with
  date carry; decoding shifts UTC back to local for the canonical string.
  Keep all 100ns digits and validate local and UTC years without JS `Date`.
- DECIMAL/NUMERIC values cross the engine/TDS boundary as canonical
  fixed-scale strings. `decimal.ts` rounds to the TYPE_INFO scale, validates
  the declared precision before encoding, then emits the sign byte followed
  by little-endian unsigned magnitude; decode returns a string, never Number.
- DONE_COUNT is status bit `0x0010`. With NOCOUNT OFF, DONE/DONEINPROC carry
  that bit and the uint64 affected-row value; with NOCOUNT ON, the bit is clear
  and the field is zero. The token itself, MORE/FINAL and ERROR state, and final
  DONEPROC remain present. Visibility is captured per statement rather than
  inferred from the session after the batch finishes.
- Character TYPE_INFO collation bytes are derived from catalog names through
  `Collation.ofName`: LCID 0x0409, sensitivity flags for ignore-case/accent,
  version 2 for Latin1_General_100, sort id 52 for linguistic collations, and
  Binary2 flag/sort-id 0 for BIN2. The login ENVCHANGE remains the default
  SQL_Latin1_General_CP1_CI_AS bytes.
- Fixed-width result metadata uses BIGCHAR (0xAF) and NCHAR (0xEF), distinct
  from BIGVARCHAR (0xA7) and NVARCHAR (0xE7). Unicode TYPE_INFO lengths are
  encoded in bytes, so nchar(n)/nvarchar(n) advertise 2n while values retain
  their character width.
- Proven non-null tinyint, smallint, int, and bigint result columns use fixed
  INT1/INT2/INT4/INT8 TYPE_INFO with no metadata or row-value length prefix.
  Nullable results continue to use width-specific INTN.
- FOR XML text mode uses the magic result-column name with NVARCHAR(MAX)
  TYPE_INFO and PLP values. FOR XML TYPE uses the unnamed XML TYPE_INFO and
  XML PLP codec. Both paths stream values beyond 8 KiB through ordinary
  COLMETADATA/ROW framing.
