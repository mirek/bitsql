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
| Views | Subplan inlined by the binder | Updatable-view rules are strict (4403/4405/4406, 404 for OUTPUT of an unmodified base table); DML through a view reaches its one modified base table, the view WHERE restricts rows and WITH CHECK OPTION cascades (550) (`traps/view-updatable-rules`, `views/*`) |
| OUTPUT clause | COLMETADATA sent before the statement runs; rows evaluated per modified row | A run-time error still sends the (possibly partial) result set first, with the rows processed before the failing row; INSERT evaluates its whole source first. Buffering all rows and checking before emitting is a false green (`output/stream-errors`) |
| UPDATE/DELETE ... FROM duplicates | First match per target row | Which of several matching source rows wins is plan-dependent: 2-row VALUES keeps the first, a 3-row VALUES capture kept the last. Corpus cases use equal values for duplicate matches (`output/join-targets`) |
| User functions | Scalar: session callback per call; inline TVF: `WithParams` subplan; multi-statement TVF: `UserTable` | Errors inside a scalar/inline function report the *caller's* line and ERROR_PROCEDURE NULL; a multi-statement TVF error adds 3621; parameter defaults apply only to an explicit `DEFAULT` argument (omitting it is 313); TVF argument-count errors on a schema-qualified name report line 13 (`udf/*`) |
| Cursors | Snapshot root plus iterator | Only `STATIC`, `FAST_FORWARD`, `LOCAL` in v1; others raise an explicit error |
| `@@ROWCOUNT` | Session register | Reset by many statements, including `SET` options, `PRINT`, `BEGIN TRAN` and `COMMIT` |
| Result metadata | Binder-computed | COLMETADATA type/length/precision/nullability must not depend on row values; empty results still carry exact metadata. Rules: docs/reference/result-metadata.md |
| Constant folding | Binder folds constant CASE/IIF/COALESCE/arithmetic | Folding changes metadata: lengths shrink to the selected branch, failing folds become nullable (result-metadata.md) |
| ORDER token | Binder-computed ordinals | Emitted for ORDER BY results with projected ordinals (0 = hidden key), but not for every ORDER BY (all-NULL constant keys, window-only ordering, derived TOP ordering omit it). Rules: msduck `docs/order-token.md` |
| `DONE` tokens | Per statement | `DONE_COUNT` presence depends on `NOCOUNT`; `DONEINPROC` vs `DONE` depends on proc context |
| String → integer | `parse_int_text` in `src/core/types` | Only ASCII spaces are trimmed (tab/NBSP fail); `'+ 7'` is 7 and `''`/`'-'` are 0; bigint failures are 8114, not 245; over 4000 UTF-16 units is 8152 even under TRY_CAST |
| Integer `%` | Checked BigInt arithmetic | `INT_MIN % -1` raises 8115 (not 0), like `INT_MIN / -1` |
| `decimal` division | Truncating quotient at the result scale | Division truncates (2/3 → 0.66666666) while scale reduction elsewhere rounds; integer literals next to decimals are typed `numeric(digits,0)` (`1.5*2` is numeric(4,1)) |
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
| Linguistic collations | Approximated weights (`collation_compare.mbt`) | NUL is ignorable, version-0 tables ignore all surrogates; é = e+U+0301, ß = ss (nvarchar; varchar under SQL_ collations: ß ≠ ss, sorts between ss and st); fullwidth/kana-insensitive even in CS_AS. Punctuation/symbol order and non-Latin scripts are approximations; word sort (hyphen ignored) is unverified |
| varchar code page | CP1252-only Strings | Unicode → varchar converts per UTF-16 unit with SQL Server's best-fit table (captured, `cp1252_best_fit.mbt`), else `?`: a surrogate pair becomes `??`, not one `?`. Binary collations order varchar by these bytes (`'€'` < NBSP), not by code point (`collation/cp1252-best-fit`) |
| Collation "no collation" | Coercibility in `bind/collation.mbt` | Two implicit collations meeting in `+`/CONCAT/CASE/UNION ALL are fine until used: comparing is 4191, returning the column 451, a direct clash 468. Coercibility flows through derived tables/CTEs (a `COLLATE` inside stays explicit); ISNULL takes the first argument's collation (`collation/deferred-conflicts`) |
| NULLIF / ISNULL metadata | Binder | `NULLIF(1,1)` is tinyint (literal typed by value) and folds; ISNULL is NOT NULL when a constant argument folds to a value although `CAST(1 AS int)` alone is nullable (`collation/expression-metadata`) |
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
| Trigger `inserted`/`deleted` | pseudo-tables in scope 3 (session/trigger.mbt) | Scanning them returns the rows newest first (VALUES ('a'),('b') → b, a), visible through IDENTITY in an audit insert without ORDER BY | triggers/after-insert-audit |
| RAISERROR under XACT_ABORT | `exec_one` disposition | RAISERROR never rolls back or aborts the batch under XACT_ABORT ON (implied in triggers); THROW does | triggers/rollback-in-trigger |
| NOCOUNT inside modules | `Session::done` | DONEINPROC tokens disappear entirely under NOCOUNT inside triggers/procedures, even in a SQL batch | triggers/after-update-columns |
| Deadlock victim | `LockManager::request` | With equal cost SQL Server kills the session that has waited longest, not the one that closed the cycle; the victim's error comes before the rollback ENVCHANGE (locking/deadlock-two-tables) |
| READ COMMITTED reads | `Session::lock_reads` | A plain SELECT blocks on another transaction's uncommitted row (locking READ COMMITTED; READ_COMMITTED_SNAPSHOT is OFF by default), and a transaction sees rows other sessions committed after its BEGIN (locking/read-committed-blocks, blocked-update-resumes) |
| `AT TIME ZONE` on a datetimeoffset | `tz_offset_at` (types/timezone.mbt) | A local time leaving 0001..9999 is not an error: SQL Server clamps to the min/max UTC value at +00:00; local (datetime2) input that overflows is 9813 | timezone/at-time-zone#038-dto-clamp-min |
| `AT TIME ZONE` near a new year | annual rule evaluation | SQL Server picks the rule year from the standard-time clock and compares the daylight clock without its year: real one-hour offset blips (Central Brazilian 1904-01-01 03:00 UTC); an IANA/tz model is wrong here | scripts/gen-timezones.py window checks |
| `sys.time_zone_info` | rows at the request clock | "current" reads the server's local clock as a wall time per zone, not the UTC instant: it lags `SYSUTCDATETIME() AT TIME ZONE` around DST changes | timezone/at-time-zone#063-catalog-consistent-with-at-time-zone |
| SET options | `Session::set_options` | Ignoring a SET silently is a false green: ANSI_NULLS OFF, IMPLICIT_TRANSACTIONS ON, ROWCOUNT n, DATEFORMAT dmy, QUOTED_IDENTIFIER OFF all change results. bitsql applies what it models and raises 50100 for the rest |
| Batch compilation | statement-at-a-time binding (session) | SQL Server compiles the whole batch first: a compile error (8117, 206, 402, 207 on an existing table, …) in any statement means no statement of the batch runs, not even BEGIN TRY's tokens. bitsql binds each statement when it runs, so earlier statements execute; it does mark such errors uncatchable by TRY (msduck try-binding-error still differs in the TRY tokens) |
| Multi-row VALUES | `unify_values_rows` (session/dml.mbt) | Each VALUES column is unified over all rows before converting to the target column: `VALUES (1), ('abc')` fails with 245 even into a varchar column, and sql_variant columns store the unified base type (variant/insert-values) |
| Simple parameterization | `session/simple_params.mbt` | INSERT/UPDATE of a permanent table without variables/functions/subqueries types string literals varchar(8000)/nvarchar(4000): visible as SQL_VARIANT_PROPERTY MaxLength 8000 of stored variants; temp tables keep the literal length (variant/insert-values) |
| sql_variant comparison | `compare_variants` (types/variant.mbt) | Different families compare by family rank, not value: int 1 < float 1e0 and N'z' < 1, while int 1 = decimal 1.0 = money 1; strings compare collation properties before text (variant/compare-order) |

| Date strings | `types/date_parse.mbt`: legacy parser (datetime, smalldatetime) and new parser (date, time, datetime2, datetimeoffset) | The same string parses differently per target (`10:11 1/2/2024` is a datetime but not a date; `.1234` fails only for datetime); legacy failures split into 241 (aborts the batch) and 242 (statement only); `13/1/2024` is 242 for datetime, 241 for date (datestrings/*, docs/reference/date-strings.md) |
