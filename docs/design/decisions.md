# Decisions log

Dated amendments to the original design draft (2026-10-03). Newest last. Each
entry: what changed, why, and which page was updated.

## 2026-10-03: project setup

- **Module layout uses `source = "src"`.** MoonBit code lives in `src/core/**`
  and `src/host`, keeping `harness/` (Node) and `docs/` out of moon's package
  scan. Package paths are `mirek/bitsql/core/<pkg>`. (architecture.md)
- **New `moon.mod` / `moon.pkg` DSL**, not the deprecated `moon.pkg.json`.
  Toolchain at setup: moon 0.1.20260920, moonc v0.10.14. (docs/moonbit/VERSIONS.md)
- **`moonbitlang/async` pinned to 0.22.4.** Since the draft it gained wasm1, JS
  and Windows support, so a non-native host is no longer blocked on the library.
  The native host remains the product. (architecture.md)
- **Event `now` is 100 ns ticks since 0001-01-01 UTC** (the `datetime2` epoch),
  so the core never converts epochs. (architecture.md)
- **Emulator error numbers 50100–50199**, severity 16, message prefix
  `Emulator:`. (fidelity-traps.md, scope.md)
- **Result metadata is binder-computed**, never derived from row values; lesson
  carried over from msduck. (ir.md, fidelity-traps.md)
- **Corpus bootstrapped from msduck captures**, because the target app's suite is
  not in this repo yet. Its capture stays phase 1 work, blocked on access.
  (verification.md, roadmap.md)
- **Phase 0 and phase 7** added to the roadmap for setup and packaging.

## 2026-10-03: statement-restart instead of resumable operators

The draft's `step` function suspends *inside* operators on `NeedLock`. Making
every Volcano operator resumable in MoonBit is costly and error-prone.
Instead:

- Procedural code (batch, proc, trigger, dynamic SQL bodies) compiles to a flat
  instruction list with jumps (IF/WHILE/BREAK/TRY/CATCH/GOTO/RETURN become
  jumps). Session execution state is a stack of frames `{code, pc, variables,
  temp objects}`, which makes it resumable at statement boundaries.
- Each simple statement (query, DML, SET, DDL) runs atomically against a
  snapshot of the session's transaction root. Before touching data it requests
  the locks it needs. If any lock must wait, the statement's private changes
  are discarded and the session parks with `pc` still on that statement. Once
  the lock is granted, the statement restarts from scratch. Locks granted
  before the wait are kept, as SQL Server keeps them.
- Counters that SQL Server never rolls back (identity, sequences, rowversion,
  NEWSEQUENTIALID) are restored from the statement-start snapshot on a
  restart, because from the client's point of view the statement ran once.
- Items already produced by earlier statements in the batch are kept. The
  restarted statement's partial items are dropped.
- (2026-10-04: ATTENTION is implemented by re-running a parked request in
  cancel mode, see the dated entry below.) Attention and time limits are checked between statements; a single
  statement is not time-sliced in v1. `Yield` remains available for later.

Effect: `NeedLock` is per statement, not per row. Deadlock detection and lock
fidelity are unchanged. (execution.md updated.)

## 2026-10-03: parser packages

- **`core/ast`, `core/lex`, `core/parse` instead of one `core/ast`.** The binder
  imports only the AST; the lexer is reusable for `GO` splitting; the parser is
  the largest compile unit. `ast` owns `Span` and `SyntaxError` (both other
  packages import it). (architecture.md)
- **Spans are UTF-16 code-unit offsets** (MoonBit `String` indexing, also TDS
  UCS-2) plus 1-based line/column counted on `\n`.
- **Reserved words are SQL Server's official list**, not mssqlite's ad-hoc one:
  `THROW`, `OUTPUT`, `USING`, `OFFSET`, `TRY`, `CATCH` stay non-reserved like on
  SQL Server (so `SELECT 1 THROW ...` misparses exactly like SQL Server does).
  Errors near a reserved word are 156 ("near the keyword"), others 102.
- **Scalar vs condition grammar.** Comparisons, predicates and NOT/AND/OR only
  parse in condition positions (WHERE/ON/HAVING/WHEN/IF/WHILE/CHECK, function
  arguments, parentheses), so `SELECT 1 = 1` is a 102 like on SQL Server.
- **Module bodies.** CREATE PROC/TRIGGER bodies run to the end of the batch;
  VIEW/FUNCTION must be followed only by `;`. All of them (and CREATE SCHEMA)
  must be first in the batch (error 111). Each module node keeps its source
  text in `definition` for `sys.sql_modules`.

## 2026-10-03: value types (`src/core/types`)

- **`SqlType` keeps `Decimal` and `Numeric` apart** (same semantics, different
  wire type: captures show NUMERIC operands yield NUMERICN results), and adds
  money, float/real, char/binary, date/time and legacy datetime types beyond
  the ir.md sketch. Character types carry a `Collation`; lengths are `Int?`
  with `None` = max, as sketched. (ir.md sketch is superseded by the code.)
- **`Value` is not self-describing**: conversions, arithmetic and comparison
  take the binder's `SqlType` alongside, so length/precision/collation come
  from metadata, never from values. Decimal = BigInt coefficient + scale;
  datetime2 = Int64 100 ns ticks since 0001-01-01; datetimeoffset = UTC ticks
  + offset minutes; legacy datetime = (days since 1900, 1/300 s units);
  uniqueidentifier = 16 storage-order bytes; varchar = CP1252-only String.
- **`SqlError` (number, severity, state, message) is the core-wide error
  type**, defined in `src/core/types/error.mbt`.

## 2026-10-03: request restart replaces statement restart (concurrency)

The engine handles each request (batch or RPC) atomically and buffers its
whole response until the request ends. That allows a simpler model than
resumable statements:

- A statement that must wait for a lock **parks the whole request**. All of
  the request's private effects are discarded (session state, temp objects,
  the transaction view and the server database map are restored to request
  start). Locks it acquired before the wait are **kept**, as SQL Server keeps
  them, so deadlock cycles stay detectable.
- When a lock is released (commit, rollback, end of an autocommit statement),
  the engine re-runs the woken sessions' parked requests from the start, in
  the same `handle` call, and sends their responses then.
- Deadlock: the lock manager picks the victim. If it is the requester, the
  statement fails with 1205 and the transaction rolls back. If it is a parked
  session, that session's request is re-run with "fail on next wait", so the
  1205 surfaces at the same statement with the same preceding output.
- The interpreter therefore stays recursive; the instruction-list design is
  no longer needed.

Known gap: autocommit writes made earlier in a parked batch become visible to
other sessions only after the batch completes, while SQL Server publishes
them immediately. Listed in fidelity-traps.md.

Lock resources (design: storage-concurrency.md):
- UPDATE/DELETE/MERGE take X on each modified row's primary key, or on its
  row id without one.
- INSERT takes X on the new key (a second inserter of the same key waits,
  then gets 2627 or proceeds).
- Reads with `UPDLOCK`/`HOLDLOCK`/`SERIALIZABLE`/`XLOCK` hints lock the point
  key when the WHERE clause fixes the primary key with equalities, otherwise
  the whole table. Plain reads under RCSI take no locks.

## 2026-10-03: commits rebase instead of failing (50107)

Concurrent transactions on one database used to raise 50107 at COMMIT
whenever another session had committed in between. Now `Db::rebase(base,
view, onto)` re-applies the transaction's changes, diffed per object and per
row against its base, onto the newest committed state. Key locks guarantee
that two writers never change the same row, so the merge is exact; a
conflicting change no lock prevented (DDL vs DML on the same table, DDL on the
same object) still raises 50107. The same rebase runs at the start of each
statement under lock-based isolation levels, so READ COMMITTED transactions see
other sessions' commits as SQL Server does. SNAPSHOT keeps its start state.
The row diff is O(changed tables' rows); a write log would make it
O(changes) if this ever shows up in profiles.

## 2026-10-03: user-defined functions run in the session

Scalar UDF bodies are procedural, and exec cannot run statements, so the
binder emits `ExprKind::UserFn(id, args)` (arguments already converted to the
parameter types) and the executor calls back into the session through
`Ctx::user_fn`; multi-statement TVFs are `Plan::UserTable(id, args)` fed by
`Ctx::user_table`. The session (`session/udf.mbt`) runs the body in a frame of
its own with a small control-flow interpreter (IF/WHILE/BREAK/CONTINUE/
RETURN) that delegates the statements CREATE FUNCTION allows to `exec_stmt`
and discards their tokens. Inline TVFs never reach the session at run time:
the binder binds the stored query with the parameters as variable slots
0..n-1 and wraps it in `Plan::WithParams(args, plan)`, which evaluates the
arguments in the caller's context. Parsed definitions are cached per object
id in `Server.udfs`, keyed on the definition text (ALTER replaces it).
Anything a function cannot leave with (lock waits, control flow) becomes an
`Emulator:` error.

## 2026-10-03: time zone rules come from SQL Server, not IANA

AT TIME ZONE and sys.time_zone_info use tables generated from a dump of the
oracle's own answers (`scripts/timezones/sqlserver-timezones.json` →
`scripts/gen-timezones.py` → `src/core/types/timezone_data.mbt`), not from
IANA tzdata or a CLDR Windows→IANA mapping. SQL Server applies Windows
yearly rules, extrapolates the first and last rule over years 1–9999, and has
year-boundary quirks (one-hour blips) that no IANA-based model reproduces.
The core stays pure: no OS time zone database at run time. The rules model
is described and checked in docs/reference/at-time-zone.md; zone-years whose
local-time resolution the model cannot reproduce raise 50100 instead of
guessing. sys.time_zone_info reads the server's local clock (UTC in bitsql)
as a wall-clock time in each zone, as SQL Server does.

## 2026-10-03: a work budget per request (50108)

Execution is single-threaded and requests are not preempted (request
restart cannot resume mid-statement). One runaway request, such as an
endless WHILE or a huge cross join in a buggy test, would stall every other
session forever, where SQL Server keeps serving them and the client's timeout
cancels the request. Each request therefore has a deterministic work budget
(rows filtered, join pairs, loop iterations; `Runtime::charge`), default
300M units, host `--max-request-work N`. Exceeding it fails the request with
Emulator error 50108, which TRY cannot catch. Deterministic counts keep
replays identical; a wall-clock limit would not.

## 2026-10-03: sql_variant values carry their base type; host-tied properties

`Value::Variant(base value, base type)` keeps the full declared base type
(varchar(3), decimal(10,2), nchar(10)) because SQL_VARIANT_PROPERTY, the
TDS encoding and comparisons depend on it; NULL stays `Value::Null`. Every
consumer of a variant goes through `@types` (cast, compare, assign,
sql_variant_property); the binder rejects variant operands of built-ins and
operators with SQL Server's errors before any implicit conversion could
happen (bind/fn_variant.mbt), and unknown built-ins raise 50100 rather than
converting.

Assignment conversions (INSERT/UPDATE columns, SET/SELECT/FETCH into
variables, parameters, PRINT) now go through `@types.assign`, which applies
the implicit-conversion rules sql_variant needs (257 out of a variant, 206 for
max types into one). Other types keep the previous explicit-conversion
behaviour (bitsql still raises 529 where SQL Server raises 206 for e.g.
`DECLARE @d date = 1`).

SERVERPROPERTY reports the oracle image's values (Developer edition,
EngineEdition 3) so clients branch like they do against the container.
Host-tied values (MachineName, ServerName, ComputerNamePhysicalNetBIOS) come
from `Config::server_name`, now passed to every session (also @@SERVERNAME);
ProcessID is the constant 1. CONNECTIONPROPERTY's address/port properties
raise 50100: the pure core does not know socket addresses, and inventing them
would be a silent approximation.

Simple parameterization is emulated only where it is observable (literal
lengths of values stored into sql_variant columns of permanent tables); the
qualifying statement shapes are the captured ones (session/simple_params.mbt).

## 2026-10-03: DML through views, CTEs and derived tables as a leaf projection

A view, CTE or derived DML target is not rewritten at the AST level. The
session (`session/dml_view.mbt`) binds the target query's FROM with
`bind_dml_source`, so the occurrence of the one modified base table carries
row ids, and wraps it in `Project(Filter(..., WHERE), view columns ++
underlying row)`. That `DmlLeaf` replaces the target occurrence in the
statement's own FROM (`bind_dml_source(view=...)`), so nested views compose
recursively. SET/INSERT columns map to base columns through `base_of`;
OUTPUT images and WITH CHECK OPTION predicates are recomputed from the new
base image with the stored `refresh` steps. Shapes outside "SELECT ... FROM
... WHERE" (TOP, UNION, nested WITH) and views with INSTEAD OF triggers stay
50100.

## 2026-10-03: user-defined types, table-valued parameters and synonyms

The v1 scope listed TVPs and user-defined types as out of scope; both are
now emulated because `mssql` applications send `sql.Table` parameters.
Types live in the database value (`@store.Db` types map, own namespace,
merged by `Db::rebase` like objects) and are not objects (no sys.objects
row, captured). A table type keeps its type table; `DECLARE @t <type>`
copies it into the session's table variables. READONLY parameters share the
caller's table variable instead of copying it (they cannot be modified:
10700 is a compile-time check), so procedures, functions (the table id is
passed as an int argument; inline functions map the parameter in the
binder, `Env::table_params`) and sp_executesql see the same rows. A TVP
from the wire is loaded into a new table variable with the type's
constraints. Synonyms are store Modules of kind SN resolved late
(`Session::deref_synonym`) by the catalog hooks, DML targets and EXEC.
## 2026-10-03: approximate and sampled query results raise instead of approximating

APPROX_COUNT_DISTINCT returns the exact distinct count only while it is at
most 30, the range where every capture (8 types, 3 value sequences) matched
SQL Server's estimate; above that, and under ROLLUP/CUBE/GROUPING SETS (where
SQL Server carries its sketch across groups), it raises 50151. TABLESAMPLE
honours 0 and 100 PERCENT (deterministic) and raises 50150 otherwise: SQL
Server samples whole pages, so even REPEATABLE results depend on page layout
bitsql does not have. PIVOT is bound as an Aggregate over CASE arguments plus
a Sort on the grouping columns, wrapped in `NoNullWarning`; UNPIVOT has its
own `Unpivot` plan node.

## 2026-10-03: xml values as trees, FOR XML text via a column-name marker, batch precheck for xml

`Value::Xml` holds a parsed tree (`@xml.Xml`: top-level nodes plus a context
path for `nodes()` rows) rather than text, so methods navigate without
re-parsing and a `nodes()` row can refer to its node and ancestors (`..`).
The canonical text is produced on output. FOR XML TYPE builds the text and
re-parses it preserving whitespace (the generated text has none that is
insignificant). The top-level FOR XML text result is NTEXT on the wire; there
is no SqlType for ntext, so `session/wire.mbt` maps the reserved column name
`XML_F52E2B61-18A1-11d1-B105-00805F49916B` to NTEXT. xml methods are
`Fn::Named("XML.VALUE" | "XML.QUERY" | "XML.EXIST")` calls (the XQuery text
is a literal argument, compiled once and cached) and nodes() a `TableFn`, so
the IR expression enum did not grow. SQL Server reports xml type errors when
compiling the whole batch; bitsql binds statements one at a time, so
`session/precheck_xml.mbt` binds the batch's table-free statements up front
and fails the batch only for xml-related compile errors (statements over
tables are compiled when they run, like deferred name resolution).

## 2026-10-04: server cursors re-read through the binder's plan

Keyset and dynamic cursors over a single table are modelled row by row:
the bound plan `Project(Filter/Sort/Top*(Scan))` is rewritten so the scan
yields row ids (`Scan(rowid=true)`) and the projection appends hidden
columns (row id, unique key, ORDER BY keys). Keysets store row ids and key
values at OPEN and re-read through a `Project(Scan)` plan; dynamic cursors
re-run the query (without its ORDER BY) and sort and position by the hidden
ordering tuple. Re-reads are cached while `Db::same_table_data` holds, and
run with the variable values captured at OPEN. Queries of other shapes
(joins, views) keep the requested type's metadata but read a snapshot, and
FETCH raises an Emulator error once a base table changed (no stale rows).
Changes made by other sessions are seen through the session's normal view;
multi-connection cursor visibility is not captured.

## 2026-10-04: JSON aggregates, FOR JSON shape, JSON error aborts

- **JSON_ARRAYAGG / JSON_OBJECTAGG keep their plain call name** (so every
  "is this an aggregate" check sees them); the parser appends a marker string
  literal (`@ast.JSON_AGG_MARKER` + `N`/`A` [+ `J`]) carrying the NULL ON
  NULL / RETURNING clauses, and an inner ORDER BY becomes `within_group`.
  `@ir.AggFn` gained `JsonArrayAgg` / `JsonObjectAgg`; JSON_OBJECTAGG's key
  travels in `AggCall.separator` (window calls: the second argument).
- **`@ir.Plan::ForJson` carries a `JsonShape`**: per-column "JSON text"
  flags (resolved by the binder through derived tables and views) and FOR
  JSON AUTO levels, so the executor never inspects expressions.
- **JSON run-time errors end the batch** (`session/interp.mbt`
  `json_aborts_batch`), and FOR JSON's 13600/13620 plus ISJSON's 1023 are
  whole-batch compile errors (`session/precheck_json.mbt`), following the
  precheck_xml pattern. (docs/reference/json.md)
## 2026-10-04: .NET culture data generated from the oracle; system TVFs through the catalog

FORMAT and PARSE need .NET Framework culture data (separators, patterns,
month/day names). Rather than transcribing CLDR or .NET sources, which
differ from what SQL Server's runtime actually prints (fr-FR, hu-HU, de-CH
all have surprises), `harness/gen/cultures.mjs` formats probe values in
each culture on the oracle and reconstructs the data (patterns by mapping
a probe date's fields back to tokens). The generated
`exec/culture_data.mbt` is committed; real cultures missing from it raise
50173 (FORMAT) / 50171 (PARSE) instead of falling back to a guess, while
names whose language the oracle does not know format like the invariant
culture, as SQL Server does. The session language reaches FORMAT through
`@@LANGUAGE` (exec `global(ctx, Language)`), so whatever SET LANGUAGE
stores flows in without a second runtime field.

System table-valued functions whose rows the session computes from
constant arguments (sys.dm_exec_describe_first_result_set) go through a
new `Catalog.system_tvf` hook: the binder folds the arguments and turns the
rows into a VALUES plan with base-like column metadata, so the executor
stays unaware of them. sp_describe_first_result_set shares the same core
(session/describe.mbt).

## 2026-10-04: database options on the server, RCSI as "no read locks"

ALTER DATABASE settings live in `Server.db_options` (lowercased name →
immutable `DbOptions`: collation, compatibility level, RCSI, snapshot
isolation, cursor default, read-only, user access, recovery, ON/OFF option
flags), not in `@store.Db`: ALTER DATABASE cannot run in a transaction
(226), so the options never need rebasing, and request restarts and
`emulator.snapshot` copy the map. `CREATE DATABASE … COLLATE` sets it too.
Readers: `Session::db_collation()` (literals, variables, parameters, new
columns, catalog view columns, savepoint names, case-sensitive object name
checks), `rcsi()`, `check_snapshot_allowed()` and the read-only check.

READ_COMMITTED_SNAPSHOT needs no row versions: a session's uncommitted
changes already live only in its transaction view, and every READ COMMITTED
statement starts by rebasing its transaction onto the newest committed
state (`refresh_tx`, see "commits rebase" above). With RCSI on,
`read_lock` therefore just returns no lock for plain READ COMMITTED reads;
the statement sees the last committed state as of its start and never
blocks. READCOMMITTEDLOCK, UPDLOCK/HOLDLOCK/XLOCK hints and all writes keep
their locks; REPEATABLE READ and SERIALIZABLE are unchanged. SNAPSHOT
transactions (already "no rebase, no read locks") now fail with 3952 when
the database does not allow snapshot isolation, as SQL Server does.

master stays alterable with `ALTER DATABASE CURRENT` (SQL Server: 12104 for
tempdb/model/msdb, and master is not a user database) because master is the
case database of process-isolated harness runs. A write while the database
is READ_ONLY is detected in `Session::write` and turned into 3906 when the
statement ends (its output is dropped, the batch ends), which covers every
write path without touching each one.

## 2026-10-04: SET DATEFORMAT / SET LANGUAGE travel with the cast

String ↔ date/time conversions read the session's date order and language
through `@types.DateSettings` (`Runtime.dates`), passed as an optional
`dates~` argument of `@types.cast` / `try_cast` / `assign` / `render` and
threaded by the executor (CAST/CONVERT nodes, date functions, DATE_BUCKET,
PARSE) and the session (assignments, column conversions, RPC parameters).
The default is us_english / mdy, so callers that never see session
strings stay unchanged. The binder does not know the session settings, so
it no longer folds string ↔ date/time casts (`session_dependent_cast` in
`bind/fold.mbt`): they are evaluated at run time, where SQL Server's
dateformat-dependent conversions are evaluated too. Language data (34
languages: names, aliases, date order, first weekday, month and day names,
INFO 5703 text) is generated from the oracle's sys.syslanguages
(`scripts/gen-languages.py`). SET LANGUAGE applies the language's DATEFORMAT
and DATEFIRST unless SET DATEFORMAT / DATEFIRST already ran in the same
request (captured; flags reset per request). Error messages under a language
with localized messages (German, French, …) stay English: fidelity trap.

## 2026-10-04: lock manager fast path; window partitions and running aggregates

Large statements were quadratic: every row an INSERT writes takes a key
lock, and each lock request scanned every grant (8,000 rows: 7.5 s). The
lock manager now counts grants and waiters per table per session; when no
other session touches the table, a request is granted by appending, without
the conflict scan or in-place upgrade (duplicate entries of one session never
conflict and releases remove them all). The exact algorithm still runs as
soon as a second session is involved. Window functions partition by sorting
on the partition key (was a linear search per row over all partitions), and
COUNT/COUNT_BIG/SUM over frames that grow from the partition start are
computed as prefix aggregates with the same per-addition overflow checks
(running SUM over 20k rows: 8.2 s → 24 ms).

## 2026-10-04: sort-based grouping, statement memo for subqueries, lookup indexes

GROUP BY, DISTINCT, UNION/EXCEPT/INTERSECT and DISTINCT aggregate inputs
searched the groups found so far for every row (20k rows, 5003 groups:
~20 s each). They now sort row positions by `compare_rows` (the order whose
ties are exactly `same_row`'s equality: collation-aware, trailing spaces
ignored, NULLs equal), take runs of equal keys as groups and number them by
first appearance (exec/grouping.mbt), so results keep the old first-
appearance order and `prefer_representative` spellings; EXCEPT/INTERSECT
test membership by binary search over the sorted right side.

Subqueries ran once per outer row. `subquery_rows` (exec/memo.mbt) keeps a
statement memo keyed by the plan object: a subquery with no outer-row
references, no `@@` globals, user functions, FOR JSON/XML, or volatile
functions (NEWID, RAND, NEXT VALUE FOR, SCOPE_IDENTITY, ERROR_*, …) runs
once, and later evaluations reuse its rows while every table it scans has
the same data stamp and every variable it reads the same value. The stamp
(`Ctx::stamp`, `Session::data_stamp`) changes whenever a table's
`TableData` is a different value (`Db::table_data`, `physical_equal`), so
writes inside the statement invalidate it; catalog views are never
memoized. A reuse replays the run's side effects on the runtime (the 8153
flag, the row counter used by NEXT VALUE FOR). IN / NOT IN over a memoized
set binary-searches its sorted non-NULL values (same `compare` and
collation as the linear loop; a NULL in the set still makes a miss
unknown). The session clears the memo at every statement start, nested ones
included. Keeping today's per-row semantics was chosen over SQL Server's
observed one-time evaluation: `SELECT @t = @t + (SELECT COUNT(*) FROM pd
WHERE k > @t) FROM pc` gives 21 on SQL Server 17.0.5005.3 (subquery run
once) and 9 here (rerun when @t changes), as before; that shape is
undocumented and plan-dependent.

Correlated `column = outer value` lookups (EXISTS / scalar subqueries on
unindexed columns) scanned the inner table per outer row. `seek_rows` now
asks `Session::seek`, which also uses non-unique unfiltered indexes covering
the pinned columns (not for char/varchar keys, whose `=` follows code page
1252 rules index keys do not), and otherwise `cached_lookup` indexes the
table on the lookup's second use in a statement under the conjuncts' own
collation and ansi flag, valid while its data stamp holds. Candidates come
back in row id order and the whole predicate is re-applied, so rows and
order equal a scan's. Table indexes are only used when the `=` compares
under the column's collation.

Found while measuring: foreign key checks scanned the referenced table per
row (`fk_has_key`; INSERT of 20k child rows: 38–49 s), cascades searched the
removed keys per child row, and MERGE evaluated ON for every (target,
source) pair (20k rows: 110–156 s). FK lookups now use a unique index on exactly
the key columns, else a sorted key index per table state (`fk_cache`,
built on the second lookup, cleared per statement); cascades binary-search
the removed keys; MERGE matches through the equi-join index
(`@exec.match_pairs`, the full ON re-checked per candidate pair). Like the
seeks, only candidate pairs are evaluated, so an ON or WHERE conjunct that
would raise on a non-matching row no longer does (SQL Server's seek plans
behave the same way). `harness/bench/bench.mjs` (`npm run bench`) times
these shapes on a release build.
## 2026-10-04: long tail round 4 (coordinator + three forks)

Corpus 20,088/20,558 → 20,453/20,587 passing (process isolation; 29 new
captured `tail/` cases, no regressions). Design points worth keeping:

- **Batch-level checks grow in `session/precheck*.mbt`.** SQL Server compiles
  the whole batch first; bitsql binds per statement. Rather than a batch
  compiler, syntactic or catalog-only checks that SQL Server reports for the
  whole batch run before execution: table hints (`precheck_hints.mbt`, two
  passes: 321/1047/10746 for the whole batch, then object checks), TOP
  counts, window arity / missing OVER, MERGE WHEN clauses, undeclared table
  variables. Checks that need binding (8117 of COUNT(NULL)) still go
  through the binder.
- **Two plan rewrites in the binder**, both because SQL Server's plans make
  them observable: a `WHERE` that is a false comparison of integer literals
  replaces the source with an empty VALUES, and WHERE conjuncts that read
  only the left input of CROSS/OUTER APPLY are pushed below the Apply
  (`push_filter`). Other predicate pushdown is not attempted (plan-dependent).
- **BACKUP / RESTORE**: parsed so that file-independent errors are exact
  (911 + 3013 for a missing database, 155 for unknown options). Superseded
  2026-10-04 by "BACKUP / RESTORE as an in-memory backup store" below.
- **EXEC sp_prepare in T-SQL** compiles a single SELECT through the
  describe path (`describe_batch`) to send its metadata; other single
  statements are Emulator errors rather than "prepared" without a compile
  check.
- **Table variables** are visible only in the frame that declared them
  (`find_table_var` used to search every frame, so dynamic SQL could see the
  caller's variables).
- **ANSI_NULLS OFF** (fork B) is a binder rewrite of `=`/`<>` against NULL
  literals and variables plus a per-module setting stored at CREATE time
  and applied while the module runs; the other non-default SET options are
  reported but their effects remain Emulator errors.
- **System catalog rows** (fork A): `sys.system_objects` / `system_columns`
  are generated data (`scripts/system-catalog/*.tsv` from the oracle →
  `session/sysviews_system_data.mbt`, ~470 KB of source) rather than
  hand-written seeds; user object ids start at 1221579390 with SQL Server's
  stride so captured ids match. The data is parsed once into a lazily
  filled module-level cache (deterministic, so core stays pure) with
  by-id and by-name maps: `OBJECT_ID(N'sys.x')` evaluated per row of an
  11.5k-row `sys.all_columns` scan took 7 s with a linear name search.
- **Compatibility level in the binder** (fork C): `Catalog.compat_level`
  exists only to keep SOUNDEX's pre-110 H/W rule; behaviour of levels below
  170 is otherwise still not modelled (trap row "Compatibility level").

## 2026-10-04: long tail round 5 (tail5: coordinator + three forks)

- **json values are canonical text.** SQL Server stores json in a binary
  format; bitsql keeps the text SQL Server prints back (`Value::String`
  under `SqlType::Json`), produced once by `types/json_type.mbt` on every
  conversion into json (CAST, assignment, INSERT/UPDATE, arguments,
  RETURNING JSON, JSON_MODIFY/JSON_QUERY of a json document). The JSON
  functions keep working on text; json documents only switch their error
  states. What depends on the binary form stays an Emulator error
  (DATALENGTH). The parser works on the UTF-8 bytes because SQL Server's
  error positions are byte offsets.
- **json type checks share the xml guards** (`bind/xml_methods.mbt`:
  comparison, sort, DISTINCT, set operations, built-in arguments) and the
  batch-level precheck (`precheck_xml.mbt` now also counts json compile
  errors), since both types are non-comparable and their errors are batch
  compile errors.
- **Process isolation runs each case in its own database** (harness
  `runner.mjs`). The six cases failing only in process mode read `master`
  as another database; the emulator's master needed no change. Database
  isolation and process isolation now agree, at ~20 s extra per full run.
- **Linguistic comparison fast paths** (fork A): ASCII text past the common
  prefix streams without building collation element arrays, and an
  identical leading run is skipped unless it ends in a space or ignorable
  unit (trailing-space trimming is the only contextual rule). Precomputed
  sort keys per value were left out: they would touch every sort and group
  operator, and the remaining slow case (first difference at a non-ASCII
  character) is ~4x the integer cost, not 10x.
- **Syntax error recovery** (fork B1): the parser collects several errors per
  batch with the yacc rule SQL Server shows (three accepted tokens before
  the next report; only 102/156/319 recover), instead of stopping at the
  first. Named windows are expanded in the parser (`parse/window.mbt`), so
  the binder only sees ordinary OVER clauses; `NEXT VALUE FOR … OVER` is a
  window function (`WinFn::NextValue`).
- **sp_prepare of DML compiles through the real executor** (fork B2):
  `Session::compile_only` runs the statement's exec path and stops at the
  OUTPUT header, so prepare-time errors and metadata come from the same
  code as execution. READPAST checks run when a table is actually read
  (`bind/readpast.mbt`), because SQL Server raises 650 at run time.

## 2026-10-04: ORM compatibility suite (harness/orm)

Corpus 20,507/20,604 → 20,519/20,618 passing (14 new `orm/` cases, two of
them failing on purpose to document gaps; no regressions). knex, Sequelize,
TypeORM and Prisma run the same workload against the oracle and bitsql
(`cd harness/orm && npm test`); only plan-dependent row order and
server-wide object ids remain (`harness/orm/known.json`). Design points:

- **The suite compares what the application observes**, step by step:
  returned values, error numbers/messages and the SQL each tool logs.
  Logged SQL is the sharpest probe of catalog fidelity: ORMs build later
  queries (and migrations) from earlier catalog answers, so a different
  row order or column flag shows up as different SQL text. Client-side
  noise (Sequelize transaction ids, savepoint names, clock values, SQL
  Server's generated constraint suffixes, the database name) is
  normalized in `lib/trace.mjs`, nothing else.
- **It stays out of `scripts/check.sh`**: ~270 npm packages, a Prisma
  schema engine binary and the oracle are needed. Every divergence is
  reduced to a captured `harness/corpus/orm/` case, which the gate does run.
- **Unsorted DISTINCT is sorted.** SQL Server's DISTINCT without ORDER BY
  comes out of a sort on the select list for the small inputs ORMs read
  (catalog queries); bitsql now sorts too instead of keeping first
  appearance. One captured TypeORM query (DISTINCT with OR-ed seeks) keeps
  predicate order on SQL Server: plan-dependent, listed as known.
- **Object ids stay server-wide.** SQL Server numbers each database from
  1221579390; bitsql's counter is shared because identity counters,
  compiled UDFs and key-range locks are keyed by object id alone. A
  per-database counter was tried and reverted: identity values of tables
  in different databases collided at once. Doing it right means keying
  those by (database, id) first (roadmap).
- **Malformed RPCs are answered, not dropped.** Decode errors that SQL
  Server reports (4002 truncated PLP, 8016 zero-length TYPE_INFO) are a
  `TdsError::RpcStream` the engine turns into ERROR (+ rollback) + DONE;
  other malformed input still closes the connection.
- **System procedures implemented in T-SQL inside SQL Server**
  (sp_addextendedproperty …) are emulated for results and errors only;
  their internal DONEINPROC/ENVCHANGE streams are masked in the corpus
  (`-- @mask tokens/stream/done/rowCount`).

## 2026-10-04: TLS in the host

- **Ciphertext never reaches the core.** The draft (protocol.md) had the
  core unwrap handshake packets via extra `Input`/`Output` variants. Instead
  the engine only decides (PRELOGIN reply as captured: OFF → OFF, ON/REQ →
  ON, NOT_SUP → NOT_SUP) and says `StartTls(id)` / `EndTls(id)`; the host
  unwraps PRELOGIN packets (`@tds.Reassembler`), wraps each server flight in
  one PRELOGIN message (packet id 0, as captured) and feeds OpenSSL. Event
  logs keep plaintext, so replay is unaffected by key exchange randomness.
- **TLS 1.2 maximum**, set through an `OPENSSL_CONF` the host writes at
  startup (`moonbitlang/async/tls` exposes no protocol options). SQL Server
  does TLS 1.3 only for TDS 8; under TDS 7 wrapping, TLS 1.3 session tickets
  would arrive wrapped after the client stopped unwrapping.
- **A built-in self-signed certificate** (CN=localhost, public key in
  `src/host/tls_builtin_cert.mbt`) stands in for the certificate SQL Server
  generates for itself; clients still need `trustServerCertificate`, as with
  the real server. `--tls-cert/--tls-key` override it, `--no-tls` restores the
  old refusal. A loopback handshake at startup turns a missing libssl or a bad
  key into a logged "TLS disabled" instead of failed logins.
- **No TDS 8 (`encrypt: strict`)**: the oracle image refuses it as well; a
  TLS ClientHello as the first bytes is malformed TDS and closes the
  connection.

## 2026-10-04: BACKUP / RESTORE as an in-memory backup store

Fixture cloning (`BACKUP DATABASE foo TO DISK=… WITH FORMAT, COMPRESSION`,
`RESTORE HEADERONLY/FILELISTONLY`, `RESTORE DATABASE foo_copy … WITH
REPLACE, MOVE …`, msdb history) was reported as unsupported. The reporter
needs neither persistence nor Microsoft-format files. Corpus `backup/*`
(clone-fixture, errors, media-sets) plus msduck gaps-backup.

- **Backup files live in the server, keyed by the device path**
  (`session/backup.mbt`, `Server.backups`), for the process lifetime. A
  backup set holds the immutable `@store.Db` (O(1), like
  `emulator.snapshot`) plus the state kept outside it: `DbOptions`
  (recovery, collation, compatibility, files, family), identity counters,
  sequence states and the procedures (server-wide by name; a restore
  re-registers the backup's and drops the old target's that no other
  database defines). The file system is never touched: a path is missing
  (3201) exactly when no BACKUP in this process wrote it, and a BACKUP to a
  directory that does not exist succeeds (SQL Server: 3201 state 1). Paths
  compare case-insensitively with repeated slashes collapsed (captured).
  `emulator.restore` does not roll back backup files or msdb history.
- **A restored copy keeps the original's object ids** (captured: OBJECT_ID
  equal in both). Identity counters were keyed by object id alone, which
  ids unique per server made safe; they are now keyed by
  `Session::ident_key(scope, t)` ("database:id" of the table scope's
  database, so three-part DML into another database counts there; the bare
  id for temp tables and table variables). A RESTORE that creates a
  database goes through `Server::create_database` (next free database_id,
  so DB_ID, sys.databases and three-part names see the copy; corpus
  `backup/clone-three-part`); one restored over keeps its id.
- **Database files and family.** `DbOptions.files` holds (logical,
  physical) pairs once a RESTORE moved them (else `name` / `name_log` in
  /var/opt/mssql/data); sys.database_files reads them. `DbOptions.family`
  is a GUID assigned at the first BACKUP and carried by RESTORE; 3154 is a
  family mismatch, 3159 an existing same-family database not in SIMPLE
  recovery, both skipped by REPLACE. Over an existing database the files
  stay where that database keeps them unless MOVEd; otherwise the backup's
  paths are used and a path used by another database is 1834 + 3156 per
  file, then 3119.
- **Media sets as captured**: FORMAT starts a new media set; INIT keeps the
  media set but replaces its sets; NOINIT (default) appends. Compression is
  a media property fixed at FORMAT (appended sets inherit it); asking for
  the other setting is an Emulator error (SQL Server's behaviour there was
  not captured).
- **Synthesized values.** Page counts are always a fresh empty database's
  (360 data + 2 log pages, captured), so "Processed n pages" is exact only
  for empty databases; durations are 0.001 s (MB/sec follows); BackupSize is
  (pages + 9) × 8 KB as captured, compressed size equals it; LSNs come from
  a server counter; GUIDs from the engine RNG; dates are the request time;
  TimeZone 0. Corpus cases mask these columns and the 3014 text. STATS = n
  prints exact multiples of n and 100 (SQL Server prints the percentages
  it reached, e.g. 11, 20, 32 for STATS = 10; STATS = 50 matches).
- **msdb history** (backupset, backupmediaset, backupmediafamily,
  backupfile, restorehistory, restorefile) are read-only scope-2 virtual
  tables (`session/msdb_backup.mbt`) with msdb's column types; RESTORE adds
  no backupset row (captured: it references the existing one).
- **3101 reads a session's own database**, not a USE inside dynamic SQL it
  is running (captured: RESTORE succeeded while another session waited in
  `EXEC('USE copy; WAITFOR …')`); `Session.outer_dbs` tracks it. 3102 does
  use the current context, dynamic USE included (captured).
- **Emulator errors** (50100): BACKUP LOG outside SIMPLE recovery (4208 is
  exact), DIFFERENTIAL, ENCRYPTION, MEDIANAME, EXPIREDATE, BLOCKSIZE and
  other unlisted options, several/URL/TAPE/logical devices, BACKUP or
  RESTORE of master/model/msdb (tempdb is 3147), RESTORE LOG / LABELONLY /
  REWINDONLY, NORECOVERY, STANDBY, STOPAT, PARTIAL.

## 2026-10-04: ATTENTION cancels a parked request by re-running it

A request can only be "running" across events while parked (lock wait,
application lock, WAITFOR); everything else completes inside one
`Engine::handle` call, so an ATTENTION arriving later finds its response
already sent and only needs DONE_ATTN. For a parked request the engine calls
`Session::attention()` (withdraws the lock request, sets `cancelling`) and
re-runs it from the start, as it does for deadlock victims. Completed
WAITFORs are passed again; the first wait that would park instead raises
`Park` with `attn.hit` set. The innermost `exec_one` rolls that statement
back (statement level), applies XACT_ABORT, and lets `Park` unwind; the
request then keeps its state (no request snapshot restore) and
`finish_attention` rewrites the tail of the response to SQL Server's cancel
completion (session/attention.mbt). The engine sends that response and then
DONE_ATTN as its own message. Not covered: cancelling a CPU-bound request
(no time slicing); a wait inside a trigger rolls back only the trigger's
statement, not the firing one.

## 2026-10-04: server-wide database discovery, cross-database names

- **Databases have ids on the server** (`Server.db_ids`: master 1 … msdb 4,
  then the lowest free id from 5; unverified, the shared oracle's ids are
  not reproducible, so cases only compare facts about ids).
  sys.databases, DB_ID, DB_NAME and the server-level views (databases,
  server_principals, syslanguages, time_zone_info, dm_*) list every
  database, whatever the session database or the `db.sys.` prefix is.
  Before, only the four system databases and the *session's* database were
  listed, so a fixture's `IF DB_ID(N'foo') IS NOT NULL DROP DATABASE foo`
  silently skipped the drop (compatibility report; corpus
  `database/cross-database`). `--database` and `--auto-create-databases`
  go through `Server::create_database` and get ids too.
- **Three-part names reach other databases' tables** through a table scope
  `OTHER_DB_SCOPE (100) + database_id` (session/storage.mbt): `db_of` /
  `write` map it to that database, so reads, INSERT/UPDATE/DELETE/MERGE,
  TRUNCATE, FK checks and key locks (object ids are server-wide) work
  unchanged. `find_table` used to drop the database part, which resolved
  `foo.dbo.t` in the session database: every name with a database part now
  resolves there or nowhere (208 for a missing database, as captured).
- **A transaction spans databases** (`Tx.parts`: one base/view per database,
  joined at first use; savepoints and statement rollback snapshot every
  part; COMMIT rebases every part before writing any). This also fixes
  `USE other` inside a transaction, which used to write past the
  transaction. Autocommit statement rollback restores every database the
  statement changed (a copy of the database map per statement).
- **DDL runs in the named database by switching the session database for
  the statement** (`in_scope_database`, no ENVCHANGE): CREATE TABLE (2702
  for a missing database), ALTER TABLE, CREATE INDEX, DROP TABLE's
  dependency check; SELECT INTO writes the other scope directly. Another
  database's catalog views (`db.sys.x`, `db.INFORMATION_SCHEMA.x`) and
  OBJECT_NAME(id, db_id) are computed the same way (binding id
  `view + (database_id + 1) * 2^20`), so DB_NAME(), TABLE_CATALOG and the
  database collation follow. OBJECT_ID, IDENT_*, COL_LENGTH accept
  `db.schema.t` (`name_target(other_db=true)`; other name_target callers,
  sp_help and friends, keep refusing other databases).
- **Not emulated (50100)**, because their bodies or semantics bind names in
  their own database: views, functions, procedures-as-objects, synonyms and
  sequences of another database (`check_other_db_module`), DML on another
  database's table that has triggers or whose defaults / computed columns /
  CHECKs call functions or sequences, and other DDL on another database's
  objects (DROP INDEX, CREATE/DROP of modules, synonyms, sequences, types,
  SET IDENTITY_INSERT, INSERT BULK, ALTER SCHEMA TRANSFER). CREATE VIEW /
  PROCEDURE with any database prefix is SQL Server's 166 (batch compile
  error, reported on line 13). Procedures are still stored server-wide by
  name (pre-existing), so `EXEC foo.dbo.p` finds `p` whatever database
  created it.

## 2026-10-05: @@VERSION names the bitsql release

A compatibility report could not tell which bitsql build it had reached: the
image had no labels (0.1.1) and SQL showed only `Microsoft SQL Server 2025
(bitsql emulator)`. `@@VERSION` is now `Microsoft SQL Server 2025 (bitsql
emulator X.Y.Z)` with X.Y.Z = moon.mod `version`
(`src/core/exec/version.mbt`, checked equal by `scripts/check.sh`;
`host --version` prints it). `@@VERSION` already differed from SQL Server's
multi-line banner, and SERVERPROPERTY('ProductVersion') stays 17.0.5005, so
clients that gate on the product version see no change (knex, Sequelize,
TypeORM and Prisma ORM suites unchanged). Release images also carry the
`org.opencontainers.image.version` / `revision` labels (since 0.1.2).

## 2026-10-05: sort keys, hash grouping, set-at-once DML

Profiled with gdb stack sampling (perf and valgrind are unavailable on the
dev host; see the moonbit skill). A persistent red-black tree in place of
`store/pmap.mbt` was considered and rejected: the map already is a
persistent balanced (AVL) tree with the same bounds, and the time went
elsewhere.

- **Sort keys** (`types/sort_key.mbt`): every sort derives a `SortKey` per
  value once (integers, date/datetime2 ticks, and linguistic strings as
  their collation-element levels in one int sequence) instead of
  re-deriving collation elements in each comparison. Pairs of other kinds
  compare the original values with `compare`, so the order is `compare`'s
  by construction; `sort_key_wbtest.mbt` checks every pair over special
  units and nine collations. Binary collations (space padding is not a
  prefix order) and SQL sort orders on varchar (NUL padding) get no text
  key.
- **Hash grouping**: GROUP BY / DISTINCT / UNION / COUNT(DISTINCT) hash
  rows of exact keys when each column holds one key kind, keeping the
  first-appearance numbering; other rows still sort.
- **Stable merge sort** (`exec/stable_sort.mbt`) for ORDER BY, window and
  ordered-aggregate sorts: `Array::sort_by` is an unstable quicksort that
  fell back to heap sort on periodic keys. Ties now keep scan order (the
  corpus has no case whose result changed).
- **UPDATE / DELETE / MERGE apply their rows once**: the statement's final
  state was computed two or three times (uniqueness check, FK check,
  final write; cascades too, which also advanced the rowversion counter
  twice). It is now reused unless OUTPUT INTO wrote in between. Rows
  whose index entries do not change only replace their value
  (`same_index_entries`), and large deletes rebuild the row and index
  maps in O(n) (`Db::delete_rows`). Error paths still replay the original
  row-by-row order, so the failing row and OUTPUT rows are unchanged.
- **Compiling MERGE** (batch prebind, sp_prepare) no longer runs the
  source query and matching before stopping at the OUTPUT header.
- **Multi-row INSERT** (64+ rows, no self-referencing FK, no
  IGNORE_DUP_KEY): each row's unique keys are checked, index by index as
  `insert_checked` does, against the statement's starting state plus a
  hash of pending exact keys, and the rows are merged into the maps once
  (`PendingInserts`, `Db::insert_rows`, `PMap::add_all`). A key without
  an exact sort key writes the pending rows and continues row by row.
  Nothing else in the loop reads the target's own rows.
- EXCEPT / INTERSECT membership hashes exact keys; all-ASCII strings get
  their text key without building collation elements; per-row
  `check_index_options` no longer allocates closures (INSERT with FK
  45 → 27 ms).

Tie order changed: ORDER BY ties now come out in scan order where the
quicksort scrambled them. SQL Server's own tie order is plan-dependent
(probe 2026-10-05: `ORDER BY v` over a temp table with a clustered key
returned one tie group ascending and the next descending), so neither
order is reproducible; no corpus case changed.

20k-row shapes (`npm run bench`), before → after: ORDER BY accented text
115 → 28 ms, ORDER BY 25 → 9, GROUP BY / DISTINCT 29–31 → 13–16, UNION
54 → 17, EXCEPT 23 → 16, ROW_NUMBER 52 → 25, UPDATE all rows 123 → 43,
UPDATE FROM 125 → 41, INSERT with FK 39 → 27, cascade DELETE 136 → 65,
MERGE 82 → 46, 40k-row GENERATE_SERIES load 77 → 51; all 24 shapes 1.08 →
0.50 s.

## 2026-10-05: lock grants per (table, session); no lock escalation yet

The lock manager kept every grant in one flat array: a request scanned all
of them, statement end ran `retain` over all of them, and every grant
updated an occupancy map. Set-wide DML takes one X key lock per row, so
`UPDATE w SET p = p + 1` over 20k rows spent ~17% of its CPU there
(`scripts/profile.sh 'UPDATE all rows'`). Now:

- `LockManager.tables : Map[table, Map[session, Slot]]`; a slot holds the
  session's grants on that table plus counts of statement- and
  session-duration grants. A request scans only other sessions' slots on
  its own table; the "nobody else here" fast path appends to the cached
  last slot. Releases drop whole slots when the counts say every grant
  goes (commit/rollback, autocommit statement end) and skip slots without
  statement locks at statement end.
- Blocker lists stay in the old order (by each session's earliest
  conflicting grant: grants carry a sequence number), so
  `blocking_session_id` and wait-for traversal are unchanged.
- `Resource::Key(table, index, k)`: a row lock is one allocation instead
  of a `KeyRange` with an `Interval` and two `Bound`s; it is `same` as the
  point range (UPDLOCK then X still converts in place) and overlaps ranges
  that contain it. `RowLock` computes the key columns and collations once
  per statement, not per row.

Lock bookkeeping fell from ~17% to ~10% of UPDATE all rows; 20k-row
shapes, server CPU per statement on a loaded host (two interleaved runs,
before → after): UPDATE all rows 71 → 63 ms, UPDATE FROM 78 → 71,
INSERT with FK 58 → 44, DELETE parent rows 81 → 68, cascade DELETE
133 → 93, MERGE 75 → 64, DELETE WHERE IN 38 → 32.

Lock escalation was evaluated and **not** implemented. Captured on
17.0.5005.3 (probe, not kept as a corpus case): `UPDATE t SET v = 1 WHERE
id <= n` on an `(int PK, int)` table holds n KEY X + ~n/450 PAGE IX locks
for n = 6000/6100/6200 and escalates to OBJECT X (32 rows in
sys.dm_tran_locks: lock partitioning on this 32-CPU host) from n = 6240,
i.e. when key + page locks reach ~6250, not the documented 5000. INSERT
of 8000 rows and DELETE of 15000 escalate too; a 30k-row heap UPDATE
showed OBJECT X plus 6234 leftover RID X locks. The trigger counts page
locks, which bitsql does not model (rows per page depend on row width),
so the threshold in rows lies anywhere between ~3125 and 6250; escalation
also fails while another session holds a lock on the table and is retried
every 1250 locks, and `ALTER TABLE … SET (LOCK_ESCALATION = …)` is
accepted and ignored today. A faithful-where-certain variant (escalate at
6250 row locks of one statement when no other session holds or waits on
the table; honour LOCK_ESCALATION = DISABLE) is a roadmap item.

## 2026-10-05: per-request shortcuts (parse cache, first-query plan reuse)

Profiling a request loop (`WORKLOAD=requests scripts/profile.sh`) showed
a parameterized point SELECT through sp_executesql spending its server
time on parsing the text and the parameter declarations (~25%), binding
twice (batch prebind, then the run: ~45%) and batch prechecks (~10%),
and `UPDATE … WHERE id = @c` scanning the whole table. Changes, each
argued equivalent to the code it short-cuts:

- **Parse cache** (`session/parse_cache.mbt`, on `Server`): parsed
  batches and statements by text. The parser is a pure function of the
  text and no code mutates an AST after parsing. Syntax errors are not
  cached (their path re-parses with recovery). Bounded at 1024 entries
  per map (emptied when full) and 64 KiB texts.
- **precheck_batch memo**: its no-failure outcome is kept per cached
  parse and variable signature (names and types of the frame's
  variables). It is a pure function of those (its catalog callback only
  names the column in a 264 message, i.e. only on failure).
- **First-query plan reuse** (`prebind.mbt` `keep_prebound`): when the
  batch's first statement is a plain query, `exec_query` uses the plan
  the prebind just built instead of binding again. Conditions: no
  transaction (`refresh_tx` could rebase the views between the two),
  the bind left no output, CurCmd or @@ERROR change, and its deferred
  binder errors are replayed. Nothing between prebind and that statement
  changes what the binder reads (the statement prologue resets only
  per-statement runtime state).
- **DML WHERE seek** (`dml_run.mbt` `never_fails`): a single-table
  UPDATE/DELETE whose WHERE is an AND of same-type comparisons of
  columns, variables and literals runs as `Filter(Scan)`, which seeks an
  index. Such a predicate cannot raise, so row-by-row error order is
  moot, and seeks return the scan's rows in row id order.

Not done: a cross-request plan cache keyed by (text, parameter types,
settings, catalog version). The binder reads the catalog through
closures over many session states (temp tables, table variables,
transaction views, synonyms, sys views, IDENTITY_INSERT, compat level,
trigger pseudo tables), and no single version stamp covers them yet. It
needs a catalog generation counter maintained by every catalog write and
rollback first.

Request loop (1000 requests, release build, local TLS; server CPU from
schedstat): point SELECT via sp_executesql 62–79 → 38–42 µs CPU
(wall 140–166 → 117–128 µs), parameterized INSERT 64–76 → 52–56 µs,
BEGIN/INSERT/UPDATE/COMMIT 310–330 → 66–70 µs, `SELECT 1` unchanged
(~120 µs wall). Executor-bound shapes (24 bench shapes, the join +
GROUP BY report) are unchanged.

## 2026-10-05: unnesting correlated integer-key subqueries

Correlated subqueries whose correlation is `inner column = outer column`
with both sides integers (`exec/decorrelate.mbt`, hooked into
`subquery_rows` for plans the uncorrelated memo rejects) are unnested the
way Neumann & Kemper ("Unnesting Arbitrary Queries", BTW 2015) and
Galindo-Legaria & Joshi ("Orthogonal Optimization of Subqueries and
Aggregation", SIGMOD 2001) describe: the topmost Filter under unary
operators (Project, Aggregate, Sort, TOP, OFFSET, DISTINCT, Window) whose
input is uncorrelated runs once per statement state and is partitioned by
the key (hash heads + next chain, buckets in input order, NULL keys in no
bucket); per outer row the bucket rows get the whole predicate re-applied
(skipped when it is only the key conjunct) and the original operators above
the Filter run over them through a negative-id work table. When the
subquery reads no other outer column, results are kept per key value
(Neumann's magic-set domain; switched off after 4096 keys with under 25%
hits). Validity follows the uncorrelated memo: table stamps and variable
values of everything the subquery reads; the input's and each run's 8153
flag and row counter are replayed. Errors surface at the same outer row
(only successful runs are kept). As with seeks, conjuncts are evaluated on
candidate rows only. Strings, decimals, dates, bit and mixed families stay
on the per-row path (`cached_lookup` sorted index): hashing them needs
collation sort keys and conversion-aware keys. Checked by corpus
`query/subqueries-unnested` (captured) and the session test "unnested
correlated subqueries equal the per-row evaluation" (`pid + 0 =` forces the
old path). The uncorrelated memo's reuse check no longer allocates per
outer row.

20k rows (`npm run bench`, noisy shared host), before → after: EXISTS
correlated 24 → 12 ms, correlated COUNT(*) scalar 33 → 10 ms. The
uncorrelated scalar shape (`p = (SELECT MAX(p) FROM w2 JOIN w …)`) already
ran once; its 16–18 ms is the 20k × 20k equi-join itself (`exec/plan.mbt`
Join: a concatenated row and an ON evaluation per pair), not the subquery.

## 2026-10-05: executor performance push (closures, streaming, hash tables, normalized sort keys)

Profiling (`scripts/profile.sh`) showed ~45% of executor CPU in allocation
and reference-count release, with per-row interpretive overhead of
100–580 ns. The executor now compiles expressions into closures per
operator run (`exec/compile.mbt`), streams scalar aggregates and joins,
groups through accumulators, hashes integer keys in an open-addressing
table (`exec/int_table.mbt`), sorts on normalized keys
(`exec/normalized_sort.mbt`) and selects TOP n with a heap; the techniques,
the papers they come from and the measured results are in
`docs/design/performance.md` (BibTeX in `performance.bib`). Equivalence
arguments that are not obvious have whitebox tests against the code they
short-cut. Two behavior-adjacent consequences:

- Scalar aggregates of the fast kinds now evaluate their arguments row by
  row as the input streams (SQL Server's stream aggregate order) instead of
  after the whole input; a SUM overflow therefore stops before later rows,
  so a NULL after it never sets the 8153 flag (the previously "assumed"
  case is now exact). When an input row and an aggregate argument would
  raise different errors, which one surfaces follows row order.
- Named built-ins implemented only by the executor no longer consult the
  session's function chain first; `session/named_pure_wbtest.mbt` fails if
  the chain ever starts answering one of them.

## 2026-10-05: storage catalogs model page counts

`sys.partitions` and `sys.allocation_units` exist (a compatibility report:
an application's storage-size query, `SUM(used_pages) * 8192` joined on
`container_id`, failed with 50100). Row counts, ids and which allocation
units exist follow captures (catalog/storage-catalogs). Page counts are
physical in SQL Server and cannot be captured in general, so bitsql models
them from the row format (`session/sysviews_storage.mbt`: record header,
fixed and variable sections, slot array, 8096-byte pages, B-tree upper
levels, IAM page, whole extents for total_pages). The model is exact for an
empty table and a one-page table (the shapes tests assert, e.g. 16384 used
bytes before and 0 after TRUNCATE) and an estimate beyond; total_pages of a
growing table is the least faithful (SQL Server preallocates extents).
This is a deliberate approximation of a physical quantity, not of
semantics: no query result other than page counts depends on it. Ids are
`72057594037927936 + (object_id << 16) + index_id` (allocation units add
`type << 52`), stable per object and index. System tables have no rows.

Also in this change: inline `INDEX` in CREATE TABLE was parsed and its
UNIQUE / CLUSTERED silently dropped (a duplicate key was accepted) and
INCLUDE / WHERE rejected; it now builds the same index as CREATE INDEX
(catalog/inline-index-options), and a trailing comma closes a CREATE TABLE
element list (catalog/create-table-trailing-comma). The `sys.extended_properties`
descriptor, hand-added earlier, now comes from a capture
(catalog/view-descriptors-storage).

## 2026-10-06: Pure regex engine with byte and character matching

The SQL Server 2025 regex captures require both Unicode character atoms and
RE2's byte atom `\C`; scalar and table functions also expose different position
units. Add a pure `core/regex` package with an ordered instruction VM over UTF-8
bytes, rather than delegating to a host regex API. Alternative priority and
capture history are explicit. Memoized instruction/position states bound
repeated exploration; compilation, matching and caller-provided work charging
apply resource limits. Capture history is an indexed persistent log to avoid
copying group arrays on branches and recursive destruction of long histories.

The initial engine has oracle-derived tests generated by
`scripts/gen-regex-tests.py`. SQL bindings now cover all seven functions. Pinned
RE2 Unicode 15.0 tables provide properties and simple folding under their retained
BSD license, also included in the container. Oracle probes of every 15.1 property
boundary and fold pair exposed differences at 15.1 additions; the 15.0 tables
pass all 21,717 captured rows. Keep the newer probe tables to reproduce those
inputs independently from the production tables. Partial-byte captures,
lone-surrogate patterns and remaining syntax/SQL edge audits are still open;
this decision is not a claim of complete regex support.

## 2026-10-06: Native JSON values preserve storage provenance

Replace canonical strings as the runtime representation of native JSON with
`Value::NativeJson(JsonData)`. Canonical text alone cannot identify its binary
size: both JSON_MODIFY and the modify method retain allocations after shrinking
or deleting values, while JSON_QUERY rebuilds its result. Evidence is in
`sql2025/json-function-storage.sql` and the mutation allocation captures.

Fresh construction records its oracle-verified size. Native assignment retains
that provenance; textual conversion and reparsing construct new storage.
JSON_MODIFY now carries an immutable allocation tree, dictionary capacity and
location, and retained byte count. Deleted property slots preserve native
rendering order and are reused before new slots. Shared arrays and key sets are
never mutated after publication, preserving assignments and transaction snapshots.
The first construction-only checkpoint used an unknown-size marker; the captured
mutation model replaces that interim state. See the JSON reference for evidence
and the native modify statement forms that remain unfinished.

### Native JSON storage widths (2026-10-06)

The allocation model carries the document's narrow/wide format and whether
its dictionary index has materialized. These cannot be inferred from the
current JSON text after mutation. Widening rebuilds live storage before the
operation; ordinary edits retain dead allocation. See the JSON reference and
`sql2025/json-global-wide-format` / `json-wide-transitions` captures. The model
remains separate from any binary page serializer.

### Native JSON statement mutators (2026-10-06)

A SET-clause mutator is marked in the AST rather than treated as an expression
method call: JSON methods remain invalid in expression contexts. Its dedicated
binder shares JSON_MODIFY value/path type checks but retains method diagnostics
and NULL-path no-op behavior. UPDATE and MERGE supply the current target value
explicitly; MERGE binds mutators before scanning, including empty targets.
Variable mutations participate in batch prebinding and preserve SET completion
behavior. Captures and remaining storage limitations are in the JSON reference.

### JSON_CONTAINS selection semantics (2026-10-06)

JSON_CONTAINS uses a separate selection walker because extraction's null
short-circuit and missing/empty collapse do not match containment. Native
list/last parsing is opt-in; existing extraction behavior stays governed by
its captures. SQL type and collation comparisons remain in the executor.
See the JSON reference for the 255 oracle cases. Scoped PREVIEW_FEATURES
changes have no statement completion token, verified in eight batch/module
contexts (`sql2025/preview-completions`); the existing batch-final fallback
supplies DONE when no other statement completes.

### Maintained native JSON indexes (2026-10-06)

JSON indexes reuse immutable index maps but have multiple concrete path keys
per row. Native values expose live paths directly from their storage tree;
creation/rebuild, individual/bulk writes, deletion, snapshots and rebasing
maintain those entries. Query execution can seek a concrete path prefix,
then reapply the complete predicate. Subset indexes are used only when an
indexed root covers the requested prefix. A separate runtime callback keeps
JSON path candidates distinct from ordinary key equality lookups. Two tests
compare the indexed plan with a forced scan and observe scan-source access.

Native JSON_PATH_EXISTS uses containment selection: resolved empty wildcards
count as existing and strict missing branches return zero. The old text-input
path remains separate. Indexed literal-path errors are validated before result
metadata; see the JSON reference for captures and remaining index audit scope.


The JSON index lifecycle also requires disabled-clustered-table checks. Binder
catalog lookup and DML target resolution reject access; the batch precheck
catches references before a preceding REBUILD can execute. DDL lookup stays
available so a separate primary-key REBUILD and TRUNCATE can work. Thirty
additional oracle cases cover placement/options and this dependency; broader
foreign-key/indexed-view dependencies remain in the open audit.


### JSON index internal catalog state (2026-10-06)

JSON index definitions carry their internal object ID and timestamps, plus the
scalar row count retained while disabled. Rebuild preserves identity and
recomputes live counts; DROP_EXISTING allocates a new internal object. Catalog
rows expose the captured internal columns and primary-key posting types,
clustered/posting/optional array-search indexes, statistics and partitions.
Scalar counting follows live native storage with first-key-wins traversal;
containers contribute no row. Object lookup includes the internal table, but
ordinary table binding still raises 208. See the 52 internal-catalog cases and
remaining physical allocation/search work in the JSON reference.


### Typed JSON extraction and ordered wrapping (2026-10-06)

Extended extraction calls follow the constructor precedent: clauses are encoded
in the AST function name. RETURNING carries an inert CAST(NULL AS type) argument
so existing type binding supplies exact result metadata; the executor uses that
result type. Ordinary calls retain their original grammar. ARRAY WRAPPER uses
an internal flag on JsonQuery, preserving FOR JSON's structured-value marking.
Native extraction selects ordered lists with repetition, while containment
retains set-like selection. Typed conversion preserves lax NULL versus strict
error behavior and rejects oversize strings before a narrowing cast can truncate
them. Captures and diagnostic boundaries are in the JSON reference; the two
text-source 102 cases require binding and cannot be decided by the syntax-only
parser. Earlier blanket extraction gaps are removed from parse-known.

### Native mutation path and storage provenance (2026-10-06)

Native mutation resolves its path before invoking the existing text mutator
and allocation model. The same effective path drives both operations, so the
function's captured `last`-as-first behavior cannot update the text and storage
at different positions. A no-op returns the original immutable native value.
The native method has separate list/last rules; variable targets consult retained
allocation for the fresh-empty-document 22020 diagnostic, while column mutation
permits insertion into fresh empty storage. Text equality alone is not
sufficient. Error 22020 is catchable but ends an uncaught batch. Oracle evidence
is collected in the native mutation accessor, missing-parent and empty-storage
fixtures documented in the JSON reference.

### Native JSON source format and incomplete TDS replies (2026-10-06)

Native storage retains copied-array format per node. Navigation and checked
materialization are distinct: captured corruption permits size/assignment and
unaffected reads but rejects damaged subtree conversion. Conservative source
key counting drives widening; empty-container insertion can relocate dictionary
storage. See the JSON reference for captured boundaries and outstanding contexts.

A reply Disconnect item preserves metadata and preceding completions while
ending the connection without EOM or final DONE. The pure engine emits Close;
the host owns socket closure. Ordinary SELECT detects corrupted native values
before row emission and bypasses SQL TRY/CATCH, matching batch/RPC captures.
The harness permits only explicitly opted-in ECONNRESET captures, with primary
reuse failure accepted only when that primary request disconnected.

### Raw UTF-8 strings in native JSON (2026-10-06)

REGEXP_MATCHES group values can contain sliced UTF-8 sequences. Native JSON
therefore stores raw strings as bytes alongside ordinary normalized scalars.
Allocation uses byte lengths. Navigation, scalar extraction, text conversion
and native wire output have distinct captured outcomes; validation happens at
the consumer rather than rejecting the producer. JSON_QUERY and mutations
preserve untouched raw nodes. Valid complete strings retain the ordinary path.
Regex position bookkeeping precomputes prefix counts once to avoid quadratic
prefix decoding. Evidence and remaining JSON context boundaries are in the
SQL 2025 reference's raw-group section.

### Turkish collation and shared code-page data (2026-10-06)

CP1254 encoding/decoding tables come from exhaustive oracle captures and live
in a pure codepage package shared by types and TDS. Varchar conversions and wire
serialization must agree; LCID is a collation property rather than a hardcoded
1033. Turkish linguistic comparison bypasses Latin1 ASCII shortcuts in compare,
sort keys, LIKE and substring search. Captured contractions are explicit rather
than generic NFC: ö and İ differ from their decomposed spellings. Fuzzy matching
uses the same tailored elements while preserving its own ignorable rules.
COLLATIONPROPERTY returns sql_variant metadata even for integer properties.
Its generated inventory covers all 5,540 oracle collation names independently
of comparison support, avoiding false NULL values for valid unmodeled names.
Evidence is in the SQL 2025 reference and Turkish/property captures.


## 2026-10-07: typed suspension from expressions and catalog scans

Execution callbacks use the existing typed `SqlError` channel with a distinct
`Suspend` constructor for internal control flow. It has no SQL number,
severity, state or message and must never become a TDS diagnostic. Accessing
those fields on it is an invariant violation. `exec_one` converts it to the
existing request-restart path; function frames restore their state and
propagate it, and TRY_CAST cannot consume it. This keeps the core pure and
avoids a fabricated SQL error number for a host or lock wait.

`Ctx.scan_row` runs before each consumed row, including rows later filtered
out. `sys.configurations` uses it for row-level catalog locks in lock namespace
-2 (application locks use -1). The streaming executor can therefore preserve
rows emitted before a timeout. Scalar/materialized and memoized scans use the
same hook. REST configured/active state lives in master and participates in
Db rebasing and request snapshots.

sp_configure's completed read outcomes survive request replay, separately
from the rolled-back attempt state. They are reset at the start and end of
each request. This permits successive internal reads to time out independently
without repeating an earlier completed wait. See the captured configuration
contracts in `docs/reference/external-models.md`. HTTP request/result replay is
still separate unfinished work; configuration support does not imply inference.


### 2026-10-07: explicit HTTP effects and recorded completions

Embedding calls suspend through the typed control path. The engine emits an
HTTP effect and the host performs TLS/HTTP; a completion carries the response
back into the pure engine. Event logs include these completions, so replay
requires no network. A monotonically increasing generation prevents a late
response from completing a cancelled or subsequent request. Completed SQL-call
outcomes survive request restart; a changed payload is explicitly rejected
until stable replay of volatile inputs and concurrent changes is implemented.

The host uses the HTTP library's TLS passthrough mode to preserve the captured
headers: its higher-level request API adds Accept-Encoding absent from SQL
Server captures. This does not waive the remaining transport contracts listed
in [external-models](../reference/external-models.md).


### 2026-10-07: volatile evaluations survive request restart

Request snapshots now include the NEWID generator and both RAND state words.
Restoring them after an internal suspension makes replay advance each generator
only once in the final execution. Clock evaluations use a run-length encoded
history: old evaluation ordinals reuse their original event time, while an
expression first reached after resumption reads the later event time. The
history is reset per request, survives internal waits and does not freeze the
whole request's clock. The registered embedding execution captures verify these
contracts, including random continuation and post-HTTP time advancement.

The new held-response concurrency captures rule out a whole-query snapshot as
a resumption fix: unread rows and later model/configuration lookups see changes,
while the already-started call keeps its context. Full row/expression resumption
remains open; see [external-model contracts](../reference/external-models.md).

HTTP resumption must also preserve completed autocommit statements. The former
whole-request snapshot made a prefix insert temporarily disappear and allowed
conflicting writes from another connection. The statement/RPC continuation
checkpoint below fixes completed outer statements; original row context and
nested control-flow continuation remain open.


### 2026-10-07: statement checkpoints and live RPC module scopes

An HTTP wait checkpoints the pending outer statement rather than rolling back
completed statements in the request. The checkpoint retains the remaining
statement list, response prefix, variable frames and evaluation ordinals.
Transparent BEGIN/END blocks are flattened at that list boundary. Further waits
in the resumed list use the same boundary. Ordinary waits before HTTP retain
the existing request-restart path.

RPC modules carry typed internal continuations through their normal completion
handlers. Their frame, parameter slots, temporary objects and saved caller
settings remain alive until the module actually ends. Restoring frames in
place preserves the references used by parameter/output handling. Dynamic SQL
restores its caller context once; prepared RPCs retain their handle through a
wait and discard it only on an actual failure. These control transfers never
become SQL errors. The registered prefix fixtures cover batches, dynamic SQL,
stored-procedure RPCs, output parameters, temporary objects and handle reuse.

This is statement-level resumption. The pending statement still retries, so
row/scan state and nested control flow remain separate unfinished requirements.
The cancellation checkpoint below addresses the captured NULL row.


### 2026-10-07: poll embedding cancellation after row consumption

An interrupted embedding yields NULL and sets a pure runtime cancellation flag.
The streaming executor polls after handing the current row to its consumer;
this preserves a SELECT row or lets a scalar aggregate account for its NULL
before unwinding. Materialized scalar aggregates and INSERT input have their
own completion boundary. Scalar assignments poll before their statement is
allowed to complete. Existing statement rollback and attention rendering handle
the unwind. Scalar streaming aggregate warnings are retained separately because
the captured grouped/distinct paths do not emit that warning on interruption.
The 33 oracle cancellation cases are documented in the external-model reference.


### 2026-10-07: retain binding and HTTP call context across model changes

A SELECT suspended by an embedding call retains its bound query for that same
statement on resumption. The call memo checks its original SQL inputs before
reusing its prepared request and response decoder; it does not look up the
model/configuration again for an already-started call. A newly reached call
performs a fresh lookup. This preserves the pending result after model DROP or
REST disable, while the following call sees the change. Input differences
remain explicit failures pending real row/scan continuation. The nine context
captures also cover API/parameter changes and cancellation; see the external
model reference for the behavioral evidence and outstanding scope.


## 2026-10-07: Bound inference concurrency for the CI release

Use an explicit unsupported error for committed table changes during pending
embedding HTTP, rather than expanding this release into retained row/scan
execution. Compare immutable table metadata/data after rollback and before
retry, including disappeared tables/rows. The conservative check also rejects
unrelated committed table changes; external-model/configuration changes remain
supported. See [external-model contracts](../reference/external-models.md).
This implements the user-authorized CI scope in
[future work](sql2025-future-work.md); it does not claim concurrency equivalence.


## 2026-10-07: Validate releases on native hosts only

Per user instruction, amd64 hosts build/test/benchmark amd64 and ARM64 hosts do
the same for ARM64. Stop cross-compilation/QEMU work by default; separate native
hosts own architecture coverage. Releases may publish one verified architecture
first, then add another validated architecture of the same version. Never mix
versions in one manifest; coordinate manifest writes across hosts. The ongoing
0.1.24 ARM64 emulation run was stopped, and ARM64 publication is deferred to its
native host. The amd64 full release gate passed before this workflow change.

## 2026-10-07: Ship a CI-focused website with the real engine in the browser

Present bitsql as usable for application CI, with the SQL Server 2025 container
swap as the primary entry point and the existing release boundary still visible.
`website/` follows cave's directory/relative-asset pattern: TypeScript, pnpm,
Vite, Node native tests and a GitHub Pages publishing workflow. The charts use
a checked-in copy of the 0.1.24 raw comparison, including slower point reads and
the single successful cold-start sample per target.

The browser playground compiles the existing MoonBit session executor to JS;
`src/browser` is a display adapter, not a second SQL implementation. A lazy Web
Worker owns the database and receives time from the browser. Stop/reset and a
10-second timeout terminate the worker. Pending host waits/HTTP are reported as
incomplete and reset; the browser does not simulate networking or concurrency.
SQL Server smoke captures verify the JS adapter; Node/Playwright exercises the
production UI. See `website/README.md` for build and publishing details.

## 2026-10-08: Query Store is an empty-view compatibility layer

The user explicitly approved publishing empty Query Store views, working
configuration and errors for unsupported management operations, then questioned
whether real monitoring is needed in this CI emulator given overhead and effort.
This supersedes the original full-monitoring release plan. The history views
intentionally return no rows after workload; README and the Query Store design
page disclose the exception to the no-silent-approximation rule. Per-statement
collection is removed, so Query Store settings do not add measurement work to
query execution. Prior experiments and oracle captures are retained for a
future, separately justified feature. The release still requires full checks
and verified native container publication.

The user subsequently clarified that the published 0.1.25 tag must contain both
amd64 and arm64, while ARM64 does not need local runtime testing. This is an
explicit exception to the default native-only build policy: --multiarch enables
ARM64 cross-compilation on amd64 without QEMU, publishes both same-version
images, and runs only the native client suite. Default publishing remains
native-only. Do not describe the cross-built ARM64 image as runtime-validated.

## 2026-10-08 — On-demand executor diagnostics, no Query Store history

The user chose a development-oriented subset after the 0.1.25 metadata scaffold:
`emulator.explain` binds one SELECT and `emulator.profile` executes it with a
request-local observer. Reports describe bitsql's logical operators, selected
actual algorithms and deterministic storage-boundary counters; they do not
imitate SQL Server costs, Showplan or historical Query Store state. Ordinary
contexts have no observer and no new per-row profiling checks. Full monitoring,
retention and forcing remain deferred. Usage, coverage and counter limitations
are maintained in [query diagnostics](query-diagnostics.md).

## 2026-10-09 — report-driven native diagnostic history

The new compatibility report requests actual observations, superseding the
0.1.25 empty-history release boundary for ALL-mode workload capture. Native
statement boundaries now handshake with the host using recorded `Measured` and
`CpuUsed` events; startup hardware facts are recorded too. Core still performs
no I/O, FFI or clock reads. CPU is charged per engine turn, avoiding attribution
of another session's work during lock waits. Measured continuation completions
must drain lock wakeups exactly like received requests.

The advisor handles selective equality scans and exposes observed candidate-row
cost/selectivity estimates; it does not synthesize SQL Server optimizer costs.
Partition statistics reuse the already documented allocation model. All
remaining boundaries, including top-level-only timing and AUTO/CUSTOM metadata
policies, are explicit in [query-store.md](query-store.md). Plan forcing and hints
on captured IDs produce Emulator errors rather than claiming success.

### 2026-10-09: diagnostic IO and plan database lookup (0.1.28)

The 0.1.27 follow-up report requires numeric Query Store read aggregates.
Physical reads are zero: this executor has no disk-backed database pages.
Logical reads accumulate the existing storage-catalog page model over rows
retrieved at each ordinary rowstore materialized source/seek boundary (including repeated cached
source reads). User rows use the existing record/LOB/overflow footprint;
virtual catalog rows use typed payload bytes plus eight bytes per record,
rounded to 8 KiB. A B-tree seek adds one modeled lookup page. This is an
explicit emulator model, not SQL Server buffer-pool accounting or a prediction
of its IO. Source footprints are cached with immutable table data. Query Store
publishes average/last/min/max/population-standard-deviation; query statistics
publish the same total/last/min/max. No-read statements retain numeric zero.

Plan-attribute lookup publishes the observed plan's `dbid` as an int variant
and cache key. Other SQL Server optimizer attributes remain outside the
supported history subset; no object IDs, plan costs or SET option masks are
invented. Captures: `harness/corpus/report-0127`, SQL Server 2022 16.0.4236.2.
