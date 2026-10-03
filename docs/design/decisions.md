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
