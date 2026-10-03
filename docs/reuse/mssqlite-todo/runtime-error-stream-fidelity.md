# Runtime error-stream fidelity

## Evidence

Two live cases show that the error number and state can be correct while the
surrounding response stream is still incompatible.

`merge semicolon validation` reports SQL Server error 10713 on source line 5;
mssqlite reports line 1 because AST/source positions are not carried into the
error token.

`openjson strict missing path` reports the same runtime path error on both
servers, but SQL Server first emits OPENJSON COLMETADATA for an empty result and
then one final `DONEPROC`. mssqlite emits no result metadata, sends an error
`DONEINPROC` with `MORE`, then a separate `DONEPROC`.

All paths and values are declared in `packages/differential/src/corpus.ts`, and
the communication artifact now records decoded token order for both targets.

The trace additionally shows that SQL Server sends `RETURNSTATUS` between the
MERGE error and final `DONEPROC`, while mssqlite omits it. For truncation and
unique-key runtime errors SQL Server follows the primary ERROR with an INFO
token for statement termination; mssqlite currently omits that informational
part of the stream.

## Work

Preserve statement/source spans through parser and engine errors so TDS ERROR
uses the failing line. For row sources whose schema is known before stepping,
emit COLMETADATA before a runtime evaluation error. Align RPC error completion
selection with SQL Server without changing statement-continuation or
transaction semantics.

Likely boundaries are T-SQL AST source spans, engine result initialization and
error classification, and server response rendering.

## Acceptance

- The MERGE line-number expectation and all four OPENJSON stream expectations
  become stale and are removed.
- Tests cover multiline parse/compile/runtime errors, including non-first
  statements, and preserve accurate ERROR line numbers.
- Empty, successful, and failing schema-known TVFs emit compatible metadata and
  DONE-family sequences over SQL batch and RPC.
- RPC compile failures preserve RETURNSTATUS placement, and statement-terminating
  runtime errors preserve SQL Server's ERROR/INFO ordering.
- `pnpm test` and `pnpm test:differential` pass.
