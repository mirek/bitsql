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
| Result metadata | Binder-computed | COLMETADATA type/length/precision/nullability must not depend on row values; empty results still carry exact metadata. Rules: docs/reference/result-metadata.md |
| Constant folding | Binder folds constant CASE/IIF/COALESCE/arithmetic | Folding changes metadata: lengths shrink to the selected branch, failing folds become nullable (result-metadata.md) |
| ORDER token | Binder-computed ordinals | Emitted for ORDER BY results with projected ordinals (0 = hidden key), but not for every ORDER BY (all-NULL constant keys, window-only ordering, derived TOP ordering omit it). Rules: msduck `docs/order-token.md` |
| `DONE` tokens | Per statement | `DONE_COUNT` presence depends on `NOCOUNT`; `DONEINPROC` vs `DONE` depends on proc context |
| String → integer | `parse_int_text` in `src/core/types` | Only ASCII spaces are trimmed (tab/NBSP fail); `'+ 7'` is 7 and `''`/`'-'` are 0; bigint failures are 8114, not 245; over 4000 UTF-16 units is 8152 even under TRY_CAST |
| Integer `%` | Checked BigInt arithmetic | `INT_MIN % -1` raises 8115 (not 0), like `INT_MIN / -1` |
| `decimal` division | Truncating quotient at the result scale | Division truncates (2/3 → 0.66666666) while scale reduction elsewhere rounds; integer literals next to decimals are typed `decimal(digits,0)` |
| float → text | `%.6g` over a 17-digit intermediate | Exact-value or 15/16-digit rounding misprints boundary values (1.234575 prints `1.23458`); exponent has 3 digits (`1e+006`) |
| Catalog definitions | Normalized from the stored source text (`session/definition.mbt`) | `sys.check_constraints.definition` etc. are regenerated: `([x]>(0))`, IN lists become reversed OR chains, BETWEEN becomes `>= AND <=`, CAST becomes `CONVERT([int],...)`, function names lower-cased; storing the source text verbatim is wrong (corpus `catalog/definitions`) |
| ORDER BY a non-projected column | Binder metadata | Changes result flags: computed expressions lose fComputed (33 → 1) and computed catalog-view columns read as plain (33 → 9) (corpus `traps/order-by-hidden-key-flags`, not implemented) |
| DDL errors | Statement completion | Outside TRY a failed DDL statement completes with CurCmd 253 and ends the batch; inside TRY it completes with its own CurCmd (198/216/200) and CATCH runs, except compile-time 4902 and 1779/1750 which are not catchable (corpus `catalog/ddl-try`) |
| Constraint / index errors | Two messages | 2714, 1779, 1505, 1911 are followed by 1750; 3728/3725 by 3727; each 5074 dependent by 4922; inside TRY only the last reaches ERROR_NUMBER() |
| CREATE / DROP SCHEMA | Completion | Sends no DONE of its own (batch nor RPC); a batch with nothing else ends with DONE CurCmd 253 (corpus `catalog/schema-rpc`) |
| ALTER COLUMN | Nullability | Omitting NULL / NOT NULL makes the column nullable again; type changes are blocked by any dependent default, check, key or index (5074) |
| Temporal text | Per-type CAST vs CONVERT style | CAST of datetime2 is ISO but CAST of legacy datetime is `Mon dd yyyy hh:miAM`; explicit style 0 is the legacy form for every type |
| `time(n)` from text | Rounded ticks clamped at midnight | `23:59:59.9999999` as `time(0)` is `23:59:59`, but as `datetime2(0)` it carries into the next day |
| `datetimeoffset` range | UTC ticks + offset | Both the local and the UTC instant must lie in 0001..9999 (8114 state 31) |
| Linguistic collations | Approximated weights (`collation_compare.mbt`) | NUL is ignorable, version-0 tables ignore all surrogates; é = e+U+0301, ß = ss; fullwidth/kana-insensitive even in CS_AS. Punctuation/symbol order and non-Latin scripts are approximations; word sort (hyphen ignored) is unverified |
| varchar code page | CP1252-only Strings | Unicode → varchar uses a best-fit table bitsql lacks: unmappable characters raise emulator error 50104 instead of guessing |
| Built-in result metadata | Binder folds constant arguments | Most function results are nullable (flags 33) even for literals, but SIGN/CEILING/FLOOR/ROUND/RADIANS/PI over numeric literals fold to NOT NULL; LEFT/SUBSTRING/REPLICATE/SPACE/STUFF lengths come from constant arguments (REPLICATE('x', 1+2) is varchar(3), a variable count is 8000) |
| Function errors: compile vs run time | Binder vs executor raise | 9810/9806/517/289/535 arrive after COLMETADATA (run time); 8116, 155, 1023, 10760, constant negative LEFT length (536 state 6) have no result set |
| DATEDIFF / DATEPART on text | Text read as datetimeoffset(7) | DATEADD reads text as datetime, DATEPART/DATEDIFF as datetimeoffset (offset honoured, 7 fraction digits); legacy datetime fractions are exact thirds (DATEPART(ns) of .997 is 996666666) |
| Transcendental functions | MoonBit `@math` | SQL Server's libm differs by 1 ulp in places (COS(1) is 0.5403023058681397, ours …398); DEGREES/RADIANS multiply by the precomputed 180/π (π/180) |
| Binary comparison | Zero-padded byte compare | Unverified: trailing 0x00 assumed insignificant, mirroring string padding |

| Parked requests | Request restart (decisions.md) | Autocommit writes earlier in a batch that later waits on a lock stay invisible to other sessions until the batch completes; SQL Server publishes them immediately |

## Emulator errors

Unsupported features raise severity 16 errors whose message starts with
`Emulator:`. Number range: **50100–50199** is reserved (user-error range so
clients treat them as ordinary errors; above 50000 so they never collide with a
real system message). Keep the allocation table in
`src/core/types/emulator_errors.mbt` once it exists.
| Aggregate metadata | Binder rules in `bind/aggregate.mbt` | Every aggregate is nullable (COUNT is `IntN` flags 1); SUM/AVG of tinyint/smallint are `int`; SUM(decimal(p,s)) is decimal(38,s), AVG is decimal(38,max(s,6)) truncated; STRING_AGG skips NULLs *without* 8153 while other aggregates send INFO 8153 after the rows (`query/aggregate-basics`, `string-agg`) |
| Arithmetic nullability | Binder | Exact-numeric arithmetic over NOT NULL columns is nullable (`id + 1` IntN flags 33) while float arithmetic, string `+` and bitwise operators are not; derived tables drop the computed flag (`id + 1` reads back flags 1) |
| Empty grouping | `Aggregate` plan | No GROUP BY over empty input returns one row; `GROUP BY ()` and `ROLLUP` over empty input return none |
| CI-equal group keys | First/binary-min representative | Which spelling of `'a'`/`'A'` a GROUP BY / DISTINCT / UNION shows is plan-dependent in SQL Server; bitsql: GROUP BY keeps the first, DISTINCT/set operations the binary-smallest (`query/set-operations`, `traps/collation-ci-trailing-spaces`). Avoid relying on it in tests |
| Streaming errors | `@exec.stream` | Rows produced before a run-time error are sent (530 after 101 rows, OPENJSON WITH conversion 245 after row 1); a Sort/aggregate above makes the error arrive before any row |
| Recursive CTE | `Recursive` plan | Columns are nullable; 530 fires when level max+1 produces a row (MAXRECURSION 3 returns 4 rows, then the error) |
| FOR JSON | `ForJson` plan | One nvarchar(max) column `JSON_F52E2B61-…`, text split into 2033-char rows, DONE count = number of *input* rows, no rows for empty input, floats as `5.000000000000000e-001`, `/` escaped |
