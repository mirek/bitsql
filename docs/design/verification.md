# Verification

Real SQL Server is the oracle: every behavior is defined by a diff against the
`mssql/server` container, never by reading docs alone. Docs (including the
skills) are for orientation; captures are the authority.

## Layers

1. **MoonBit unit tests** (`moon test`) for pure pieces: codecs, lexer/parser,
   types, binder, executor. Byte-exact TDS fixtures come from the tds-protocol
   skill examples and from real captures.
2. **Engine-level tests** drive `Engine::handle` with recorded client bytes and
   compare the produced token stream. No sockets needed.
3. **Harness** (`harness/`, TypeScript, tedious + mssql) against the running
   binary: client-level behavior.
. **Proofs** (`moon prove`, see below) for small arithmetic kernels whose
   failure would be silent or a crash: machine-checked for every input, with
   overflow as a proof obligation.

## Differential harness

- **Corpus:** the captured traffic from one CI run of the target app (SQL batches
  and RPC calls with parameter types), plus hand-written cases for every fidelity
  trap and lock pattern, plus earlier imported SQL Server captures
  (`harness/corpus/captured*`).
- **Expected output is captured, not written:** `npm run capture` runs a corpus
  case against real MSSQL and stores the result next to it. Hand-edited
  expectations are not allowed.
- **Comparison:** result sets (values and column types), rowcounts, output
  parameters, return status, error number, severity and state, and INFO
  messages.
- **Concurrency cases:** scripted interleavings of two or more sessions. Compare
  outcomes (who blocked, who got 1205 or 2627), not timing.
- **Output:** a ranked failure list, which doubles as the roadmap.

## CI routing during the transition

- Tests verified green on the emulator go into an allowlist and run there.
- Everything else keeps running on real MSSQL in one job.
- The RAM pain disappears only when the last test leaves the MSSQL job, so
  prioritize by "what still pins us to MSSQL", not by what is most interesting
  to build.
- A nightly job runs the full suite on both and fails if any allowlisted test
  diverges.

## Formal proofs (`moon prove`)

`moon prove` (experimental, moon 0.1.20260920) lowers contracts in a
proof-enabled package to Why3 and discharges them with z3/cvc5 (installed in
the dev container image; Why3 ships with the toolchain).

2026-10-26: solver versions matter. With the dev container's z3 4.8.12 and
cvc5 1.0.8 all 87 goals prove; with z3 4.13.4 + cvc5 1.2.0 `fits` times
out. On a host without them, put those two release binaries on `PATH`.
`moon prove` caches the solvers it detected in `_build/verif/why3.conf`;
delete `_build/verif` after changing solvers (otherwise every goal is
"unknown").

`scripts/check.sh` proves every proof-enabled package with the
**machine-integer prelude** (`$MOON_HOME/lib/prelude_proof_machine_int`), so every `+ - * / %` must be
proved not to overflow. The default prelude uses unbounded integers and
proves the overflowing `pos + n > len` check below "correct".

**Where proofs live:** `src/core/proved` only. It is pure arithmetic
(Int, Int64, Bool, tuples): the proof lowering translates every type
definition of a proof-enabled package and fails on an `Array` field (and maps
String to `int`), so `tds`, `types` and the rest cannot enable proofs
themselves. Callers delegate (`@types.round_ticks` calls
`@proved.round_ticks`), so the proved code is the code that runs.
Preconditions are not checked at runtime and callers are unverified: a
contract is a guarantee for inputs in range, and the range is stated on it.

| Kernel | Proved (machine integers) | Left to tests |
| --- | --- | --- |
| `fits` (`@tds.Reader` bounds) | sound and complete, no overflow | — |
| `days_from_civil` | years 1..9999, any day 1..31 → 0..3652058 | — |
| `civil_from_days` | 0..3652058 → year 1..9999, month 1..12, day ≤ 30 in 30-day months, February ≤ 29 | February 29 only in leap years, round trip: exhaustive over all 3,652,059 days (`proved/temporal_test.mbt`) |
| `scale_unit`, `round_ticks` | exactly 10^(7-scale); half-up rounding characterized for ticks up to 9999-12-31 | — |
| `round_time_ticks` | stays in the day, a multiple of the unit | — |
| `ticks_to_datetime_units`, `datetime_units_to_ticks` | exact formula, ranges, round trip units → ticks → units | (also exhaustive) |
| `datetime_parts` | a valid legacy datetime, midnight carried | — |

Each spec was checked by mutation (an off-by-one rounding, a wrong datetime
constant, a dropped carry, a wrong month formula, the old bounds check): the
prover rejects each one.

**Bugs found while writing the specs (2026-10-11):**
- `@tds.Reader::need` checked `pos + n > len`. An NText RPC parameter or a
  LOGIN7 FeatureExt length near 2^31 (pre-auth) wrapped it negative, passed,
  corrupted `pos`, and the next read aborted the server process. `ucs2`
  passed `n * 2`, which wraps to a small positive number for some negative
  `n`. Both now go through `@proved.fits` (regression test in
  `tds/packet_test.mbt`).
- `GETDATE()`/`GETUTCDATE()` and the sysviews `dt` stamp converted the time of
  day to 1/300 s units without carrying: in the last 1/600 s of a day they
  produced a datetime at 24:00:00.000. Both use `@types.datetime_parts` now,
  as `CONVERT` to datetime already did.

**Good candidates:** pure integer code where a wrong answer is silent or an
abort kills every session: bounds and length arithmetic on wire input, clamps
on user-controlled sizes (REPLICATE/SPACE widths), calendar and scale
arithmetic, money/decimal scaling with Int64. Binary searches over
generated tables (`case_map`, `cp1254`, `tz_segment`) would need the tables as
`FixedArray`/`ReadOnlyArray`, which the prover models, instead of `Array` of
tuples, plus sortedness as an assumption about generated data.

**Out of reach today:** anything over String, Array, Map, StringBuilder or
BigInt (not modeled); bitwise operators (`<< >> & | ^`, so the byte decoders
and gzip/CRC); code that raises, aborts or interpolates strings inside a
contracted function (extract the arithmetic into a contracted kernel and keep
the error path in the caller); nonlinear facts such as the leap-year link
above (use an exhaustive test when the domain is finite). Spec-writing
pitfalls are in the moonbit skill gotchas (2026-10-11, `moon prove`).

Adding a kernel: write it in `src/core/proved` with a `where { proof_require,
proof_ensure }` contract and named predicates in a `.mbtp` file, run
`scripts/check.sh` (or the `moon prove` line from it), mutate the body once to
see the proof fail, and delegate from the original call site.
