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
