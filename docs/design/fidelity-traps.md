# Fidelity traps

Places where a plausible implementation silently diverges from SQL Server. Each
needs a dedicated harness case (`harness/corpus/traps/`). When you discover a
new trap, add a row here *and* a corpus case.

| Feature | Representation | Trap |
| --- | --- | --- |
| Collation | Per-column collation on every comparison | Default `*_CI_AS` is case-insensitive, and trailing spaces are ignored in `=` comparisons |
| `datetime2` / `datetimeoffset` | `Int64` ticks of 100 ns plus offset minutes | Never use a millisecond clock in the core: millisecond precision silently breaks comparisons |
| Legacy `datetime` (if present) | Ticks rounded to 1/300 s | Values round to .000, .003 or .007 |
| `uniqueidentifier` | 16 raw bytes | Mixed-endian wire format; SQL Server sorts by the last 6 bytes first, so `ORDER BY` on a GUID is a classic false green |
| `rowversion` | Database-wide counter bumped on every insert and update | Assigned at modification time, not commit; `@@DBTS` and `MIN_ACTIVE_ROWVERSION()` |
| `decimal` | Fixed-point big integer plus scale | Result precision and scale rules for `*` and `/`, and truncation vs rounding |
| `NEWSEQUENTIALID()` | Monotonic per instance | Only valid in defaults |
| Identity | Per-table counter | Not rolled back with the transaction; gaps are expected |
| JSON paths | Lax by default, `strict` prefix | Lax returns NULL where strict errors |
| `OPENJSON` | `TableFunction` node | Default schema returns `key`, `value`, `type`; the `WITH` clause casts |
| Computed columns | Stored `Expr` inlined by the binder | Persisted vs non-persisted affects indexability |
| Views | Subplan inlined by the binder | Updatable-view rules are strict |
| Cursors | Snapshot root plus iterator | Only `STATIC`, `FAST_FORWARD`, `LOCAL` in v1; others raise an explicit error |
| `@@ROWCOUNT` | Session register | Reset by many statements, including `SET` options, `PRINT`, `BEGIN TRAN` and `COMMIT` |
| Result metadata | Binder-computed | COLMETADATA type/length/precision/nullability must not depend on row values; empty results still carry exact metadata |
| `DONE` tokens | Per statement | `DONE_COUNT` presence depends on `NOCOUNT`; `DONEINPROC` vs `DONE` depends on proc context |

## Emulator errors

Unsupported features raise severity 16 errors whose message starts with
`Emulator:`. Number range: **50100–50199** is reserved (user-error range so
clients treat them as ordinary errors; above 50000 so they never collide with a
real system message). Keep the allocation table in
`src/core/types/emulator_errors.mbt` once it exists.
