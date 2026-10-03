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
4. **Differential** runs the same corpus against real MSSQL and the emulator and
   compares.

## Differential harness

- **Corpus:** the captured traffic from one CI run of the target app (SQL batches
  and RPC calls with parameter types), plus hand-written cases for every fidelity
  trap and lock pattern, plus cases imported from msduck's `reference/*.json`
  captures.
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
