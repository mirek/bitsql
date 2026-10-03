# ORDER token fidelity

## Evidence

The 2026-07-18 packet/token trace against SQL Server 2025 17.0.4065.4 exposed
a difference invisible to ordinary tedious row events. For an ordered VALUES
query, SQL Server's response sequence contains:

```text
ColMetadataToken, OrderToken, RowToken, RowToken, DoneInProcToken,
ReturnStatusToken, DoneProcToken
```

mssqlite returns the same ordered values and metadata but omits `OrderToken`.
The dedicated `ordered result token stream` corpus case preserves both decoded
sequences under `communication.{mssqlite,sqlServer}.tokens`.

## Work

Implement the TDS ORDER token and retain enough resolved ORDER BY information
to emit its 1-based select-list ordinals when the protocol requires it. Verify
SQL Server behavior for aliases, ordinal ORDER BY, expressions not projected,
multiple keys, descending keys, set operations, and RPC versus SQL batch before
fixing the emission rule.

Likely boundaries are T-SQL resolved SELECT metadata, `packages/tds/src/token`,
and `packages/server/src/respond.ts`.

## Acceptance

- The dedicated live case has a compatible application-response token sequence
  and no unexplained ORDER-token diagnostic difference.
- Exact TDS encoder tests use SQL Server ground-truth bytes.
- Server tests cover ordered and unordered results, including multiple keys and
  a non-projected ordering expression.
- `pnpm test` and `pnpm test:differential` pass.
