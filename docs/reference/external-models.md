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
These pure functions are not yet connected to host HTTP execution. SQL binding
and the disabled REST execution path are implemented; enabling REST and actual
inference remain open.

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


## Binding and instance configuration (2026-10-07)

`sql2025/embedding-binding` and `embedding-contracts` capture model lookup,
argument validation, execution timing and descriptors. All 32 cases pass.
Model lookup raises 15151 state 10 before argument type checks. Dotted names
are looked up as a single external model name; string literals produce syntax
1035 state 11. A CREATE in the same batch cannot satisfy an embedding model
reference at batch compilation.

Character source types and typed character NULL are accepted. Untyped NULL,
XML, native JSON, binary and integer sources raise 8116 for argument 2.
PARAMETERS accepts native JSON or untyped NULL; character/integer parameters
raise 8116 for argument 3. The result is nullable native JSON: TDS 7.4 and
`dm_exec_describe_first_result_set` expose UTF-8 varchar(max), but SELECT INTO
records system_type_id 244. TOP (0), an empty input and an unselected CASE
branch do not execute inference. Executing with REST disabled raises 31643
state 2 after result metadata.

`harness/fixtures/configurations.expected.json` contains all 107 default
`sys.configurations` rows and their captured variant base types (all int),
plus 26 sequential configuration procedure/RECONFIGURE probes. Generate the
view with `scripts/gen-sysviews.py`. Reproduce the fixture with
`node gen/capture-configurations.mjs --verify` from `harness/`; the script
mutates only its own disposable oracle, never the shared instance.

The catalog defaults and REST configuration mutations are implemented.
Enabled HTTPS inference now passes the 86 captured SQL/request exchanges.
For REST, configuration_id 16402, the default configured/active values are
both zero, minimum zero, maximum one, is_dynamic true and is_advanced false.
sp_configure changes only the configured value, and RECONFIGURE installs it.
Configured changes roll back with a user transaction; RECONFIGURE inside one
raises 574 state 0. A committed configured change still awaits RECONFIGURE.
The state lives in the master Db so existing cross-database transaction
snapshots handle rollback. Unsupported configuration mutations
must continue to fail explicitly until implemented.


Configuration concurrency is captured in
`harness/fixtures/configuration-concurrency.expected.json`; reproduce it with
`node gen/capture-configuration-concurrency.mjs` from `harness/` (default:
verify, `--force`: recapture, always a disposable oracle).
An uncommitted configured-value change blocks catalog reads, even with NOLOCK.
The scan can emit an unrelated matching row before reaching the locked row and
raising 1222 state 51. sp_configure's describe path performs three reads:
timeouts occur at lines 43, 81 and 90, each followed by DONEINPROC 193 with the
error bit; the last read has result metadata, and the procedure returns zero.
RECONFIGURE times out at the batch line with CurCmd 220. Completed procedure
reads are retained across request replay so each subsequent read can wait
independently. Captures also cover scalar UDFs, TRY/CATCH and TRY_CAST; the
internal wait is never itself catchable, while the eventual timeout is.


### Host HTTPS execution (2026-10-07)

`harness/test/embedding-http.test.mjs` compares all 86 fixture SQL results and
actual HTTPS requests against `embeddings.expected.json`, including headers,
UTF-8 byte lengths, retries and fatal completion. The fatal 596 response ends
with DONE(ERROR | SRVERROR), CurCmd 193, and a TDS end-of-message packet before
connection closure; omitting EOM prevents tedious from completing the request.

The native host verifies server certificates with system roots by default;
`--http-ca FILE` supplies PEM roots for controlled endpoints. HTTP responses
enter the pure engine as recorded events. Completed calls survive request
restart so later calls do not repeat earlier POSTs. Engine tests exercise
multiple calls, stale completion rejection, cancellation and disconnect.

This is partial inference support. Transport-specific SQL diagnostics,
credentials, ONNX, retry timing, compressed responses, redirects and concurrent
model/source changes remain open. A replay whose embedding payload changes
currently fails explicitly; concurrent source/model changes still need retained
execution state. Volatile clock and random inputs are now retained across replay. Transport failures likewise remain explicit Emulator errors.


### Volatile input and concurrency captures (2026-10-07)

`embedding-execution.expected.json` adds nine registered execution cases.
Reproduce with `node gen/capture-embeddings.mjs --execution --verify`.
GUID, unseeded RAND and clock values are normalized only after checking that
HTTP input equals the source returned by the same SQL execution. The captures
also cover multiple calls/columns/rows, seeded random continuation and time
advancing after a delayed HTTP response. All nine pass the native host.

`embedding-concurrency.expected.json` captures nine held-response scenarios;
reproduce with `node gen/capture-embedding-concurrency.mjs --verify`.
The endpoint holds the first HTTP response until another SQL connection's
mutation completes, preventing HTTP response arrival from racing that mutation.
A fresh oracle reproduced all nine. The model/configuration cases now pass
through the context suite below; the source/locking cases remain unregistered:

- Updating the consumed source retains the old value in its pending result.
- Updating/deleting unread rows affects subsequent results; a newly inserted
  later key is also read. A whole-query snapshot would be incorrect.
- Dropping the model preserves the pending row, then raises 15151 on the next
  call. Altering its MODEL changes the second request's model field.
- Disabling REST preserves the pending row, then raises 31643 on the next call.
- With the captured clustered-primary-key query, `DELETE t` (all rows)
  or dropping its table times out with 1222, while a non-key update succeeds.

These facts require retaining consumed rows and in-flight call context while
allowing later reads/lookups to observe current state. The existing request
restart path does not yet meet that contract.


### Statement and RPC resumption (2026-10-07)

The committed-prefix captures now pass: seven SQL batches, ten dynamic RPCs,
and eleven procedure/prepared RPCs. Reproduce them with
`node gen/capture-embedding-concurrency.mjs --prefix --verify`, `--rpc-prefix
--verify`, and `--proc-prefix --verify`. The three expectation files are
`embedding-prefix.expected.json`, `embedding-prefix-rpc.expected.json` and
`embedding-prefix-proc.expected.json`. The registered
`harness/test/embedding-prefix.test.mjs` checks both connections, all result
metadata/completions, and every HTTP exchange.

Completed outer statements remain committed during HTTP. Variables, table
variables, DDL and response tokens survive the wait; transparent BEGIN/END
blocks resume at their pending inner statement. A subsequent WAITFOR can park
again without replaying completed statements. RPC module scopes now survive
suspension: output parameters retain their values, temporary tables remain
available until module completion, and SET options revert at completion. A
prepared RPC returns a usable handle after suspension; the test executes it
again and checks its second HTTP request.

This does not yet preserve the pending statement's scan position/evaluated row,
or completed nested statements inside control flow and nested module calls.
The nine source/model concurrency cases above remain open.

`embedding-cancellation.expected.json` records cancellation with a held RPC
HTTP response (`--cancel-prefix --verify`). SQL Server cancels before the
response is released and preserves the completed insert. It sends an NBCROW
NULL result before DONEPROC(ERROR) and DONE_ATTN. The emulator now matches this capture, including the NULL row.

### Embedding cancellation (2026-10-07)

`embedding-cancellation-matrix.expected.json` adds 32 cases, reproducible with
`node gen/capture-embedding-concurrency.mjs --cancel-matrix --verify`. Together
with the prefix cancellation case, 33 registered cases verify prompt attention
before HTTP release, exact wire rows, completion tokens, and connection reuse.
Raw token-row observation matters: tedious suppresses its ordinary row events
once the client cancels, although SQL Server can still send a row.

Scalar expressions finish the interrupted embedding as NULL. Surrounding
COALESCE, sibling columns, subqueries and vector conversion still evaluate;
streaming SELECT emits that row before cancellation. Scalar COUNT emits 8153
but no result row, DISTINCT COUNT emits neither, and the captured grouped COUNT
emits its first group without a warning. INSERT and INSERT OUTPUT roll back the
interrupted write and emit 3621; OUTPUT metadata precedes the interruption but
no inserted rows follow. Assignments, TRY, SQL batches, RPCs and an open
transaction are covered. The preceding transaction/insert remains active after
cancellation and the follow-up rolls it back.

These captures do not establish all operator shapes or interruption points.
Concurrent source/model changes and nested statement resumption remain open.


### In-flight model context (2026-10-07)

`embedding-context.expected.json` contains nine cases, reproducible with
`node gen/capture-embedding-concurrency.mjs --context --verify`. The registered
client suite checks both connections and all requests/results. Dropping a model
or disabling REST leaves the pending call intact; a later call sees 15151 or
31643. Changing MODEL, API_FORMAT or PARAMETERS affects the later call while
the pending response retains its original decoding context. Single-call queries
and cancellation after dropping the model/disabling REST are also covered.

A suspended SELECT retains its bound plan and metadata. Completed/pending HTTP
calls retain their input values and prepared request/API context; only newly
reached calls look up current model/configuration state. Replayed input changes
still produce an explicit unsupported error until row/scan resumption is
implemented. This checkpoint does not establish nested module or DML query
binding retention, or solve source-row concurrency.

### CI release concurrency boundary (2026-10-07)

Until pending rows/scans have true continuation, any committed table data or
schema change in any database during an embedding HTTP wait raises 50100,
severity 16 (`Emulator: concurrent table changes during embedding HTTP is not
supported.`). This intentionally includes unrelated tables. Model/configuration
changes are excluded and retain their captured behavior. The snapshot is taken
after pending-statement rollback and checked inside normal statement error
handling, preserving other sessions' committed work and connection reuse.

The six source mutation cases from `embedding-concurrency.expected.json` are
registered as explicit emulator rejection tests in
`embedding-concurrency-guard.test.mjs`; they are not claimed as SQL Server
concurrency equivalence. Before the guard, deleting every source row silently
returned success because no embedding call was replayed. The broader work is
[deferred](../design/sql2025-future-work.md).
