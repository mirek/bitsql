# SQL Server 2025: CI release boundary and future work

On 2026-10-07 the user authorized parking less-used functionality so bitsql can
ship improvements for its primary purpose: replacing SQL Server in application
CI runs. This narrows the release, not the fidelity requirement. A deferred
feature is not complete; accepting syntax or returning correct simple results
does not prove its implementation. Known unsupported semantics must raise an
explicit `Emulator:` error rather than create a false green.

## Current release

Ship the oracle-verified SQL, metadata, TDS and client behavior accumulated in
the [2025 audit](sql2025-audit.md): native JSON and its tested operations, regex,
vector values and captured search behavior, fuzzy matching, bigint DATEADD,
optional-length SUBSTRING, concatenation, Base64, and tested external-model
HTTP execution. The topic references describe exact coverage and limitations;
this is not a claim of complete SQL Server 2025 equivalence.

Release gates are `scripts/check.sh`, ORM compatibility, refreshed performance
measurements, a coherent version bump, pushed commits, native-host release
validation, and publication verified in the registry. Each architecture is
validated on its own native host; foreign architecture work is not a gate.
Publishing the new container remains the definition of done.

## Deferred work

| Area | Why later / evidence needed before claiming support |
| --- | --- |
| ZSTD backup artifacts and restore | Low relevance to memory-only application tests. Requires real compressed artifacts and restoration evidence; emulated backup history is insufficient. |
| Full/differential backups on secondary replicas | Requires replica topology and architecture beyond ordinary isolated CI databases. Capture and verify real secondary behavior before implementation. |
| tempdb resource governance | Default catalog captures do not establish classification, accounting, enforcement or rollback. Requires isolated oracle work and actual limits. |
| Optional parameter plan optimization | Result equivalence is covered separately. Dispatcher/variant plans and adaptive decisions need dedicated oracle contracts. |
| Optimized locking internals | Existing application locking is not evidence of transaction-ID locking or lock-after-qualification equivalence. Capture these mechanisms independently. |
| ONNX and credential-backed inference | Keep unsupported modes explicit. Implement host effects and capture secure request/response contracts when application demand justifies them. |
| Advanced approximate vector search | Larger graph sampling/growth, tied choices, internal pages and wider index lifecycle remain open. Retain the captured supported boundary; do not claim general ANN equivalence. |
| Native JSON storage and index internals | Broader corruption/serialization/OUTPUT/cursor/index contexts and value/range access need oracle cases. Existing tested behavior is retained, not extrapolated into universal coverage. |
| HTTP inference with concurrent source changes | A pending row and ordered scan need true continuation rather than query replay. Reject unsupported mutation cases explicitly until implemented. |
| Advanced HTTP statement continuation and cancellation | Nested control flow, additional DML interruption points, implicit transactions and lock/lifecycle equivalence require focused captures. Existing registered cases are the supported evidence. |

## Follow-up discipline

Prioritize a deferred item when a real application CI workload needs it.
Follow oracle → registered corpus → implementation, and move completed items
back into the audit with passing evidence. Keep investigation details in the
existing [external-model](../reference/external-models.md),
[vector](../reference/vector.md), and other topic references rather than
repeating speculative contracts here. Fresh-database versus reused-database
embedding lock probes produced different outcomes; neither is a general
locking rule yet.
