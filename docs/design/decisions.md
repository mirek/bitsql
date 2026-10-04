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
- Attention and time limits are checked between statements; a single
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
  (911 + 3013 for a missing database, 155 for unknown options); a BACKUP of
  an existing database and every RESTORE are Emulator errors. Raising 3201
  ("cannot open backup device") would claim a fact about the server's file
  system that bitsql cannot know.
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
