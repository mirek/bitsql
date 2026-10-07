# External models (SQL Server 2025)

Captured on 17.0.5005.3, 2026-10-07. Sources:
`harness/corpus/sql2025/external-model-{ddl,contracts,boundaries,validation}`
and `catalog/view-descriptors-external-models`.

CREATE/ALTER/DROP EXTERNAL MODEL definitions are transactional and have a
separate namespace from sys.objects. They require no preview switch. Names
are single identifiers; a leading # does not make a model temporary.
Successful model DDL emits no statement DONE of its own; an otherwise empty
batch receives the final CurCmd 253 completion. DDL resets @@ROWCOUNT to zero.
Missing ALTER/DROP completes with CurCmd 170.

IDs begin at 65536 per database and remain consumed after rollback. Duplicate
names consume an ID, whereas invalid API formats, invalid JSON parameters and
missing authorization principals do not. The allocator must live outside
transaction snapshots; emulator.snapshot/restore explicitly saves it.

LOCATION is not URL-validated at definition time. API formats normalize to
OpenAI, Azure OpenAI, Ollama or ONNX Runtime. Trailing spaces are accepted but
appear as NUL characters in the catalog. Leading spaces and tabs fail. The
invalid API diagnostic is 46508, severity 15, line 16, state 32 for CREATE and
34 for ALTER, and takes precedence over missing required options or an absent
ALTER target. Invalid JSON parameters take precedence over absent credentials.

MODEL is at most 100 UTF-16 units. DDL option string literals are capped at
4000 units; error 103 prints the first 129 units of an N-prefixed string and
30 units of a varchar literal. Empty LOCAL_RUNTIME_PATH reports option
PARAMETERS, error 46504 state 43. ALTER SET() reports missing SET_PARAMETER,
46505 state 43. CREATE WITH() reports missing LOCATION, state 60.

sys.external_models exposes a native JSON parameters column, datetime2(7)
creation/modification times, and no sys.objects entry. Creation times initially
match; alteration changes modify_time even in the same batch. Rollback restores
both definition and timestamps. Catalog descriptor flags are captured rather
than inferred from values.

Embedding inference remains open; the parser accepts the captured scalar syntax,
and the binder explicitly rejects execution until inference is implemented. `embedding-contracts` captures binding and
disabled-function diagnostics against the shared oracle, where external REST
endpoints are disabled. Those captures do not establish successful inference,
HTTP request/response behavior, credentials, retries, or ONNX runtime execution.
The shared oracle configuration must not be changed to obtain those results;
use an isolated oracle and a controlled endpoint for that work. Model locking,
additional authorization principals, credential lifecycle and combined-invalid
option precedence need further captures.
