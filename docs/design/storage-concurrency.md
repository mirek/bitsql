# Storage and concurrency

Storage is a persistent (immutable) map per table and per index, so snapshots
are free and locking is an overlay limited to three modes on key intervals.

## Persistent snapshots

- A database value is a root pointer over persistent maps keyed by PK and index
  keys. `moonbitlang/core/immut/sorted_map` is the first candidate (ordered,
  persistent); swap for a persistent B-tree only if profiling demands it.
- A transaction keeps a private root with its writes. Commit publishes it;
  rollback drops it.
- **Test isolation is O(1):** seed once, snapshot, restore before each test.
  Exposed as emulator-specific procs: `EXEC emulator.snapshot 'seed'` /
  `EXEC emulator.restore 'seed'`.

## RCSI semantics to match

- **Plain reads** use a statement-level snapshot with no locks.
- **DML targets** are located on the latest committed version with U locks, then
  X on modified keys. Under RCSI, writes behave like locking read committed.
- **FK validation** reads the latest committed parent or child row with shared
  locks, not the snapshot.
- **`UPDLOCK`** reads latest committed and holds U until commit.
- **`HOLDLOCK` / `SERIALIZABLE`** hold key-range locks, including on absent keys.
  This is what makes the upsert pattern safe:

```sql
BEGIN TRAN;
IF NOT EXISTS (SELECT 1 FROM t WITH (UPDLOCK, HOLDLOCK) WHERE k = @k)
  INSERT t (k, v) VALUES (@k, @v);
ELSE
  UPDATE t SET v = @v WHERE k = @k;
COMMIT;
```

## Interval locks: the one primitive

Skip SQL Server's lock hierarchy (intent locks, pages, escalation, the Range*
modes). One primitive covers v1:

```moonbit
enum LockMode { S; U; X }

enum Resource {
  KeyRange(IndexId, Interval)   // point key = degenerate interval
  WholeTable(TableId)           // fallback when no index matches
}

struct LockSpec { mode : LockMode; duration : Duration }  // Statement | Transaction

fn compatible(a : LockMode, b : LockMode) -> Bool {
  match (a, b) {
    (S, S) | (S, U) | (U, S) => true
    _ => false
  }
}
```

| Situation | Lock taken |
| --- | --- |
| Plain read under RCSI | none (snapshot) |
| DML target rows | U while locating, X on modified keys, held for the transaction |
| FK check | S on the referenced key, statement duration |
| `UPDLOCK` | U on matched keys, held for the transaction |
| `UPDLOCK, HOLDLOCK` | U on the predicate interval, held for the transaction |
| `SERIALIZABLE` read | S on the predicate interval, held for the transaction |
| `INSERT` | X on the point key; conflicts with any range lock covering it |

## Deadlock detection

The core's scheduler keeps a wait-for graph over parked sessions and checks for
a cycle on every new wait. The victim (lowest work done, matching SQL Server's
default) gets error 1205 and a rolled-back transaction. This is mandatory:
`HOLDLOCK` without `UPDLOCK` is the textbook source of 1205, and an emulator
that hangs there turns a test failure into a CI timeout.

## Index seeks are a correctness requirement

SQL Server locks the range it seeks and far more when it scans. Lock fidelity
therefore depends on access-path choice.

- Whenever a predicate is sargable on an index, seek it and lock that interval.
- Otherwise lock `WholeTable`. Over-locking is conservative: it may add
  blocking, but never misses a conflict.

## Deterministic scheduling

Because the core returns `NeedLock` instead of blocking, and the host only feeds
a logged event stream, interleavings are deterministic and replayable from the
log. Concurrency tests become reproducible, which real SQL Server cannot offer.

## Implementation notes (core/sched)

- Conversions (a session upgrading a lock it already holds, e.g. U → X after
  `UPDLOCK, HOLDLOCK`) are served before queued new requests. Without that rule
  the upsert pattern deadlocks against its own waiter (test
  `insert into a HOLDLOCK range waits`).
- New requests queue FIFO behind earlier conflicting waiters, so writers are not
  starved by readers.
- Key ranges on *different* indexes of one table are treated as overlapping.
  Without row identity this is the conservative choice; refine when needed.
