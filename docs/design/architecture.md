# Architecture

The SQL engine is MoonBit: a pure core does TDS, parse, bind, execute, storage
and locking as one state machine; a thin native async host moves bytes and fires
timers. The TypeScript website also runs the same session executor, compiled to
JavaScript, in a Web Worker through `src/browser`. That display adapter has no
sockets or host wait/HTTP integration; see [the website guide](../../website/README.md).

```
            ┌──────────────── host (native, moonbitlang/async) ───────────────┐
 tedious ──▶│ TcpServer → reader task/conn → Queue[Event] → engine task       │
            │                                   ▲              │ Output       │
            │        timer tasks ── TimerFired ─┘              ▼ Send/Close   │
            └──────────────────────────────────────────────────────────────────┘
                                    │ Engine::handle(Event) -> Array[Output]
            ┌──────────────── core (pure, any backend) ───────────────────────┐
            │ [tds codec]* → session → [parser]* → binder([Semantics]*) → IR  │
            │      → executor (step fn, Delta consumers) → store (persistent) │
            │      → sched (interval locks, wait-for graph, 1205)             │
            └──────────────────────────────────────────────────────────────────┘
 * = the only T-SQL-specific pieces (wire adapter, parser, semantics record)
```

A MySQL dialect would replace the three starred pieces and reuse the binder,
executor, store and scheduler unchanged. The host knows nothing about SQL or TDS.

## Host boundary

```moonbit
pub enum Input {
  Connected(Int)              // connection id
  Received(Int, Bytes)        // raw TDS bytes
  Closed(Int)
  TimerFired(Int)             // lock timeout, query timeout
  Resume                      // continue a time-sliced long query
}

pub struct Event { input : Input; now : Int64 }  // now = 100 ns ticks since 0001-01-01 UTC

pub enum Output {
  Send(Int, Bytes)
  Close(Int)
  SetTimer(Int, Int)          // timer id, ms
  CancelTimer(Int)
  Yield                       // host re-sends Resume on its next turn
  Log(String)
}

pub fn Engine::new(config : Config, seed : Int64) -> Engine
pub fn Engine::handle(self : Engine, event : Event) -> Array[Output]
```

The host is a native `moonbitlang/async` program of roughly 150 lines:

- A `TcpServer` accepts connections. One reader task per connection forwards
  `Received` events into an `@aqueue.Queue`, since a socket allows only one reader
  or writer task at a time.
- A single engine task drains the queue, calls `handle` and applies outputs:
  `Send` writes to the socket, `SetTimer` spawns a task that sleeps and then
  enqueues `TimerFired`, and `Yield` enqueues `Resume`.
- When a commit releases locks, that `handle` call also returns `Send` outputs
  for the unblocked sessions. The host never knows a session was blocked.

Because the core is pure, logging the event stream of a failing CI run and
replaying it locally reproduces the run byte for byte, including interleavings,
timestamps and generated GUIDs. `host --record FILE` writes the event log
(format in `src/core/engine/event_log.mbt`, header carries the seed) and
`replay FILE [--hex]` (`src/replay`) feeds it to a fresh engine and prints every
output.

The core packages use no async and no FFI, so they compile to every MoonBit
backend (`moon check --target all` must stay green for `src/core/**`).

## Repo layout

```
moon.mod                 module mirek/bitsql, source = "src"
src/core/                pure MoonBit: no async, no FFI, any backend
  types/                 Value, SqlType, Decimal, collations, CAST/CONVERT, arithmetic, comparison
  tds/                   packet framing, PRELOGIN/LOGIN7/SQLBatch/RPC decode, token + value codecs
  ast/                   syntactic T-SQL AST, Span, SyntaxError, to_sexp printer
  lex/                   T-SQL lexer (tokens with spans), split_go_batches
  parse/                 recursive-descent parser: parse_batch / parse_statement / parse_expr
  ir/                    bound expressions and plans (typed, nullability, column origin)
  bind/                  AST → IR: names, types, metadata rules, constant folding, functions
  exec/                  expression evaluator, built-in functions, plan runner
  json/                  T-SQL JSON semantics (JSON_VALUE/QUERY, ISJSON, OPENJSON)
  store/                 persistent AVL maps, Db value (tables, indexes, modules, schemas)
  sched/                 interval lock manager, wait-for graph, deadlock victim (not wired yet)
  session/               statement interpreter: completion tokens, errors, transactions,
                         DDL/DML/MERGE/OUTPUT, cursors, procs, dynamic SQL, prepared stmts
  reply/                 response items → TDS token stream (DONE/DONEINPROC/DONEPROC framing)
  engine/                Engine::new / Engine::handle(Event) -> Array[Output]; login; event log
src/host/                native, moonbitlang/async: TcpServer, queue, event log (--record)
src/replay/              replays an event log through a fresh engine (native)
src/parsecheck/          parses SQL files / JSON batch lists (parser coverage, parse differential)
harness/                 TypeScript test tooling (tedious + mssql are the real clients)
  corpus/                SQL + RPC cases with expected SQL Server output
  src/                   runner, differential diff, capture, parse-diff, msduck importer
docs/design/             this design
docs/reference/          SQL Server rules distilled from captures (completions, metadata)
docs/moonbit/            vendored MoonBit docs (generated, see VERSIONS.md)
docs/reuse/              what to reuse from msduck / mssqlite
.claude/skills/          project skills (kept current as we learn)
scripts/                 check.sh (pre-push gate), update-moonbit-docs.py
Dockerfile               distroless image around the release binary
```

Package dependencies flow one way: `engine → session → {bind, exec, store,
reply} → ir → types`. `bind` may evaluate constant expressions through
`exec`; `exec` never depends on `bind`. The Semantics record (ir.md) is not
extracted yet: T-SQL rules live directly in bind/types.

Packages are created lazily: a directory appears when the first code for it
lands.

## Language choice

| Option | Strength | Risk |
| --- | --- | --- |
| **Pure MoonBit, native host (chosen)** | One language, one native binary, smallest image; all fidelity-sensitive code in one place | Pre-1.0 toolchain; async library API churn, confined to the host |
| MoonBit wasm core + TS/Node host | Wasm portability today | Node in the image; second language for a trivial shell |
| Pure TypeScript | Fastest iteration | Larger runtime; less learning value (mssqlite went this way) |
| Rust | Most mature product base | Slowest iteration; not the learning goal (msduck went this way) |

The core/host split is about determinism and testability, not about languages.
The harness stays TypeScript because the suite's real clients are `tedious` and
`mssql`; it is test tooling, not part of the product. The container is the
native binary on a minimal base image.

Since `moonbitlang/async` 0.22 also supports wasm1, JS and Windows, a wasm or
browser host is now possible (see decisions.md, 2026-10-03).
