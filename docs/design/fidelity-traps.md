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
| ORDER token | Binder-computed ordinals | Emitted for ORDER BY results with projected ordinals (0 = hidden key), but not for every ORDER BY (all-NULL constant keys, window-only ordering, derived TOP ordering omit it). Rules: msduck `docs/order-token.md` |
| `DONE` tokens | Per statement | `DONE_COUNT` presence depends on `NOCOUNT`; `DONEINPROC` vs `DONE` depends on proc context |
| String → integer | `parse_int_text` in `src/core/types` | Only ASCII spaces are trimmed (tab/NBSP fail); `'+ 7'` is 7 and `''`/`'-'` are 0; bigint failures are 8114, not 245; over 4000 UTF-16 units is 8152 even under TRY_CAST |
| Integer `%` | Checked BigInt arithmetic | `INT_MIN % -1` raises 8115 (not 0), like `INT_MIN / -1` |
| `decimal` division | Truncating quotient at the result scale | Division truncates (2/3 → 0.66666666) while scale reduction elsewhere rounds; integer literals next to decimals are typed `decimal(digits,0)` |
| float → text | `%.6g` over a 17-digit intermediate | Exact-value or 15/16-digit rounding misprints boundary values (1.234575 prints `1.23458`); exponent has 3 digits (`1e+006`) |
| Temporal text | Per-type CAST vs CONVERT style | CAST of datetime2 is ISO but CAST of legacy datetime is `Mon dd yyyy hh:miAM`; explicit style 0 is the legacy form for every type |
| `time(n)` from text | Rounded ticks clamped at midnight | `23:59:59.9999999` as `time(0)` is `23:59:59`, but as `datetime2(0)` it carries into the next day |
| `datetimeoffset` range | UTC ticks + offset | Both the local and the UTC instant must lie in 0001..9999 (8114 state 31) |
| Linguistic collations | Approximated weights (`collation_compare.mbt`) | NUL is ignorable, version-0 tables ignore all surrogates; é = e+U+0301, ß = ss; fullwidth/kana-insensitive even in CS_AS. Punctuation/symbol order and non-Latin scripts are approximations; word sort (hyphen ignored) is unverified |
| varchar code page | CP1252-only Strings | Unicode → varchar uses a best-fit table bitsql lacks: unmappable characters raise emulator error 50104 instead of guessing |
| Binary comparison | Zero-padded byte compare | Unverified: trailing 0x00 assumed insignificant, mirroring string padding |

## Emulator errors

Unsupported features raise severity 16 errors whose message starts with
`Emulator:`. Number range: **50100–50199** is reserved (user-error range so
clients treat them as ordinary errors; above 50000 so they never collide with a
real system message). Keep the allocation table in
`src/core/types/emulator_errors.mbt` once it exists.
