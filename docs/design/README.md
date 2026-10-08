# bitsql design

bitsql is a memory-only SQL Server emulator that real `tedious` clients connect
to over TDS, so CI no longer needs the ~1.5 GB / 2 GB RAM `mssql/server`
container. Originally drafted 2026-10-03 (Mirek Rusin); split into topic files
and amended as the project learns. Amendments are logged in
[decisions.md](decisions.md), so read that alongside these pages.

| Page | Contents |
| --- | --- |
| [scope.md](scope.md) | Goals, success criteria, v1 scope table, unsupported-feature policy |
| [architecture.md](architecture.md) | Pure core / thin host, host boundary, repo layout, language choice |
| [ir.md](ir.md) | Dialect-neutral bound IR, `Semantics` record |
| [execution.md](execution.md) | Step function, DML delta, scope stack, error model |
| [storage-concurrency.md](storage-concurrency.md) | Persistent snapshots, RCSI, interval locks, deadlocks |
| [protocol.md](protocol.md) | TDS layer |
| [fidelity-traps.md](fidelity-traps.md) | Places where a plausible implementation silently diverges |
| [verification.md](verification.md) | Differential harness, CI routing |
| [sql2025-future-work.md](sql2025-future-work.md) | CI release boundary and deferred SQL Server 2025 work |
| [query-store.md](query-store.md) | Active Query Store implementation and publication requirements |
| [roadmap.md](roadmap.md) | Phases, gates, **live status**, risks |
| [decisions.md](decisions.md) | Dated log of amendments to the original draft |

## Three principles

- **Dialect-neutral IR.** The binder resolves every dialect decision into
  explicit nodes, so the executor never branches on dialect.
- **Pure core, thin host.** `Engine::handle(Event) -> Array[Output]` is the only
  boundary. The core never performs I/O, reads a clock or generates randomness:
  time arrives on every input and a random seed at init.
- **Immutable storage.** Snapshots and rollback are pointer swaps. Locks, waits
  and deadlock detection are core state too.

## Sibling projects (reference material)

Two earlier emulators by the same author are public domain and freely reusable.
Use them for specs, captured SQL Server ground truth and test ideas, not for
architecture:

- **msduck** (Rust + DuckDB), github.com/mirek/msduck. Large `reference/*.json`
  corpus of real SQL Server captures, ~340 behavior docs, a TDS codec with tests,
  and tedious client tests.
- **mssqlite** (TypeScript + SQLite), github.com/mirek/mssqlite. TDS and T-SQL
  parser packages and a differential package.

See [../reuse/README.md](../reuse/README.md) for what has been ported and what
remains.
