# Protocol layer

The TDS codec lives in the pure core (`src/core/tds`). Reference material:
`.claude/skills/tds-protocol/` (MS-TDS digest with annotated hex examples),
`tedious` source in `harness/node_modules/tedious`, and the codecs of the sibling
projects (msduck `crates/msduck-tds`, mssqlite `packages/tds`). It starts without
TLS.

| Client → server | Server → client |
| --- | --- |
| PRELOGIN (version, encryption negotiation) | PRELOGIN response (`ENCRYPT_NOT_SUP` in v1) |
| LOGIN7 (credentials, database, options) | LOGINACK, ENVCHANGE (database, packet size, collation), INFO, DONE |
| SQLBatch (T-SQL text) | COLMETADATA, ROW / NBCROW, RETURNSTATUS, RETURNVALUE, DONE / DONEPROC / DONEINPROC, ERROR, INFO |
| RPC (`sp_executesql`, `sp_prepexec`, proc by name) | Same token stream, plus output parameters |
| ATTENTION (cancel) | DONE with the attention flag |

## Notes

- **RPC is phase 2, not later.** `mssql`'s `request.query()` with inputs sends
  `sp_executesql`; `request.execute()` sends a proc RPC. Decoding TYPE_INFO for
  parameters is needed from the first real test.
- **TLS** (2026-10-04, decisions.md) lives entirely in the host
  (`src/host/tls.mbt`, `moonbitlang/async/tls` over OpenSSL). The engine
  negotiates (`@tds.negotiate_encryption`) and emits `StartTls` before the
  PRELOGIN response and, for login-only encryption, `EndTls` before the LOGIN7
  response; it only ever sees plaintext, so event logs and replay stay
  deterministic.
- **Packet framing:** default 4 KB packets, honoring the size negotiated in
  LOGIN7. Large result sets span packets with the EOM flag on the last.
- **`FOR JSON`** results are returned as multiple rows of roughly 2,000
  characters in one `nvarchar(max)` column. Clients concatenate them, and tests
  may depend on that.
- **Info messages:** `PRINT` and low-severity `RAISERROR` map to INFO tokens;
  `WITH NOWAIT` flushes the packet immediately.
- **Catalog probes on connect:** `tedious` sends few. The harness capture
  confirms the exact set.

Wire-level findings go in `.claude/skills/tds-protocol/SKILL.md` under
"bitsql findings", not here.
