# Architecture

Everything is MoonBit: a pure core does TDS, parse, bind, execute, storage and
locking as one state machine; a thin native async host only moves bytes and
fires timers.

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
timestamps and generated GUIDs. The host supports `--record <file>` and the
`replay` tool feeds the file back into a fresh engine.

The core packages use no async and no FFI, so they compile to every MoonBit
backend (`moon check --target all` must stay green for `src/core/**`).

## Repo layout

```
moon.mod                 module mirek/bitsql, source = "src"
src/core/                pure MoonBit: no async, no FFI, any backend
  types/                 Value, SqlType, decimal, datetime2, uniqueidentifier
  tds/                   packet framing, tokens, TYPE_INFO, PRELOGIN/LOGIN7
  ast/                   T-SQL lexer, AST, parser
  ir/                    Plan, Expr, Stmt, LockSpec
  bind/                  shared binder + Semantics record (tsql.mbt)
  exec/                  step function, Delta consumers
  sched/                 interval locks, wait-for graph, 1205
  store/                 persistent maps, snapshots, catalog, virtual sys.* views
  session/               scope stack, registers, RPC dispatch
  engine/                Engine::new, Engine::handle(Event) -> Array[Output]
src/host/                native, moonbitlang/async: TcpServer, queue, timers, event log
harness/                 TypeScript test tooling (tedious + mssql are the real clients)
  corpus/                SQL + RPC cases with expected SQL Server output
  src/                   runner, differential diff, capture against real MSSQL
docs/design/             this design
docs/moonbit/            vendored MoonBit docs (generated, see VERSIONS.md)
docs/reference/          ported SQL Server behavior notes
.claude/skills/          project skills (kept current as we learn)
scripts/                 maintenance scripts
```

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
