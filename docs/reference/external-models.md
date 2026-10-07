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

## Embedding HTTP contracts

The controlled HTTPS captures live in
`harness/fixtures/embeddings.expected.json`, with inputs in
`harness/gen/embedding-cases.mjs`. They preserve both the outgoing HTTP request
and the SQL result, including metadata, diagnostics and completion tokens.
`scripts/gen-embedding-tests.py` derives pure request/response tests from them.
These pure functions are not yet connected to SQL execution; inference still
raises the explicit unsupported error.

Run `node gen/capture-embeddings.mjs --verify` from `harness/` to reproduce the
captures. The command creates its own uniquely named oracle on an automatically
assigned port, enables REST only there, trusts its fixture certificate, and
removes the container and certificate directory afterward. `--force` deliberately
recaptures expectations. The fixture must pass a successful OpenAI health check
before any new expectation file is accepted. Docker can assign a different port
after restarting a container published with port 0; refresh the connection config.
SQL Server's certificate directory is `/var/opt/mssql/security/ca-certificates`;
the capture installs the test certificate there and restarts its own oracle.

OpenAI and Ollama send `model` and `input`; Azure OpenAI sends `input` without
`model`. Optional parameters overwrite corresponding model parameters, retaining
the existing key's position. `sql_rest_options` is removed from the HTTP body.
Replacing it with an empty runtime object resets the model's retry setting.
The lowercase keys `input` and `model` are forbidden; `Model`, `user` and
`encoding_format` are accepted. Native JSON parameter arrays are rejected at
execution, with different states for model and optional parameters.

OpenAI/Azure responses select `$.data[0].embedding`; Ollama selects
`$.embeddings[0]`. The first entry wins regardless of its `index` property.
An object or mixed array is accepted as the embedding, so this step must not
apply vector validation. Only the selected subtree undergoes native JSON
conversion: `1e300` elsewhere is ignored, but inside the embedding raises 1007.
Invalid JSON (including a scalar root) is 31745; a missing or scalar embedding
path is 31744. Empty responses and HTTP 204 produce 31718, severity 17, state 21.

HTTP 408, 429, 500, 502, 503 and 504 are retryable. Exhaustion produces SQL NULL,
including when the default zero retries permits just one attempt. Captured retry
counts one and two produce two and three requests. Other captured non-2xx
statuses raise 31742 state 3. A string-valued `sql_rest_options` reproducibly
produces 596 severity 21 and kills the session; the capture reconnects only for
this explicitly declared fatal case. Host integration must handle that outcome
without crashing the emulator process.

Payload escaping is not uniform: source strings and top-level string parameters
escape `/` and use lowercase control-character escapes. The model name and
nested parameter JSON retain native JSON formatting. The fixture's
`source-control`, `model-escape` and `parameter-escapes` cases constrain these
separate paths. The harness also checks that capture inputs match the current
case definitions, so editing inputs cannot silently reuse old expectations.
