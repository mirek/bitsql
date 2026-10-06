# SQL Server 2025 vectors

2026-10-06: captured against SQL Server 17.0.5005.3 in
`harness/corpus/sql2025/vector-*.sql` and `vector-*.cases.json`. This is a partial
implementation checkpoint; the open requirements are in
[the feature audit](../design/sql2025-audit.md).

## Values and SQL surface

Float32 dimensions are 1–1998, with `DATALENGTH = 8 + 4 * dimensions`.
TDS 7.4 clients receive varchar(max), UTF-8, with eight-significant-digit
scientific JSON text. That text is **not a lossless storage format**: preserve
the exact binary32 components internally. JSON numbers round to binary32;
negative zero and underflow normalize to positive zero. Overflow is 42241 and
aborts the batch. A parsed array with the wrong dimension is 42204 state 4,
also batch-aborting; a distance dimension mismatch is state 3 and follows
result metadata. Descriptor conversion mismatches use state 1 at compilation.
`vector-json`, `vector-functions`, `vector-storage` capture these distinctions.

`VECTORPROPERTY` returns sql_variant: smallint for Dimensions, nvarchar(7)
for BaseType. Unknown properties return NULL. Vectors cannot be stored inside
sql_variant. Columns expose system_type_id 165, user_type_id 255 and native
byte lengths; describe exposes the varchar(max) fallback. `sp_columns` omits
vector columns (`vector-catalog`). Equality, sorting, grouping, DISTINCT,
set deduplication and MIN/MAX reject vectors; COUNT and UNION ALL work
(`vector-operators`). Wider operators/conversions still need auditing.

## Common result types

`vector-combinations` and `vector-precedence` capture CASE, COALESCE, ISNULL
and UNION ALL. A vector/string combination takes a variable string type whose
capacity includes the vector's native byte length (8 + 4n), not its display
length. Thus a vector(3) and varchar(7) produce varchar(20), and rendering the
chosen vector raises 42211. Constant folding can reduce a chosen string branch
to its own capacity. ISNULL retains the first vector type and nullable metadata.
Combining vectors of different dimensions fails at compilation with 42204
state 1, even in an unchosen branch. Combining with json produces json.
Binary and varbinary have distinct 206 error directions; these rules cannot be
represented by assigning vector a single ordinary type-precedence rank.
Uncaptured combinations raise an explicit emulator error.

## Norm arithmetic

`vector-norms`, `vector-norm-extremes` and `vector-norm-rounding` distinguish
an eight-lane path from a short tail. Full groups of eight accumulate in
binary32 lanes, with separately rounded binary32 squares for norm2; the lane
reduction and remaining components use binary64. Normalization rounds the
norm to binary32 before division and rounds the quotients to binary32. Zero
norms return the input unchanged. Overflow of a binary32 lane raises 8115;
a finite binary64 norm that overflows only when converted for normalization
can instead produce zero components. Do not replace this with an ordinary
mathematical norm or one uniform-precision sum.

## Distance arithmetic

`vector-distances`, `vector-distance-order`, `vector-distance-rounding`, and
`vector-distance-special` pin the floating-point reduction order. All three
metrics return binary32 promoted to SQL float (binary64 metadata).

Full blocks contain 32 components. Dot and Euclidean use four registers of
eight lanes with fused binary32 multiply-add. Registers merge pairwise, then
remaining components accumulate into the merged eight lanes. Horizontal
reduction adds halves (0+4, 1+5, …), then halves again. Euclidean first rounds
each difference to binary32 and rounds the final square root. Dot negates the
sum, including a negative-zero result.

Cosine uses two eight-lane registers, alternating each eight-component group
within the same 32-component blocks. It separately computes dot and squared
norms, rounds each square root and their product to binary32, then rounds the
ratio and subtraction from one. Zero squared norms yield distance one;
NaN after overflow clamps to zero (`vector-distance-extremes`). Thus identical
`[1,2,3]` vectors produce a small positive cosine distance, not exact zero.

A binary64 multiply/add followed by a binary32 cast is insufficient to emulate
fused binary32 arithmetic at exact rounding midpoints. `vector-distance-special`
includes tiny residuals on either side of ties, and a float32 overflow midpoint.
The pure implementation retains the TwoSum residual and corrects midpoint
rounding without FFI or host-dependent intrinsics. Generated unit expectations
come only from captured SQL Server outputs (`scripts/gen-vector-tests.py`).

## Open contracts

Preview float16 supports 3996 dimensions and two bytes/component plus an
eight-byte header. Both bases and the captured additional diagnostics after
failed declarations are now implemented. `VECTOR_DISTANCE` advertises 3–4 arguments
in error 189, but all captured four-argument calls fail with 174 state 6.
Nonempty calls outside that range emit both errors. Batch behavior is covered;
stored-module diagnostic sequencing needs more captures. Embedding generation,
external models, approximate vector indexes/search and remaining conversion,
collation, aggregate and operator contexts are not complete.

2026-10-06: `vector-float16`, `vector-float16-values` and
`vector-float16-distances` verify the implemented float16 path.
SQL Server rejects both NORM and NORMALIZE on float16 with compile-time 42246,
including typed NULL. Mixed float32/float16 conversions fail at compilation
with 42238, while mixed-base DISTANCE raises 42243 after result metadata.
Float16 input first rounds to binary32, then binary16 (the near-midpoint
values in `vector-float16-values` distinguish direct binary16 rounding).
Half overflow is 42241 state 2; overflow before the half conversion is state 1.
Half columns expose scale 1 and retain readable data after PREVIEW_FEATURES is
turned off; only new float16 declarations are rejected with 195. These captures
are registered in the passing suite. Container release validation now includes
the vector corpus in its ARM64 smoke as well as the complete amd64 suite.

The 288 float16 distance pairs also distinguish its reduction kernel: a
implementation uses the two-register cosine layout for **all three** float16
metrics and matches every captured result. Reusing the four-register float32
dot/Euclidean layout differs on 26 dot and 12 Euclidean results. `vector-dimension-limits` also verifies
1998-dimensional float32 and 3996-dimensional float16 values over TDS.

`vector-float16-contracts` pins diagnostic precedence: CAST/TRY_CAST/coercion
reject the base conversion before a dimension mismatch; DISTANCE checks its
metric, then dimensions, then base agreement, after NULL short-circuiting.
NORM/NORMALIZE argument type checks precede the float16 restriction. Existing
columns remain readable with preview off. `vector-preview` repeats identical
batch text across ON/OFF transitions; the successful-precheck cache therefore
includes preview state. Descriptor resolution receives that state in conversion,
declaration, module and describe paths; reflection of existing module parameter
types resolves float16 independently of the current switch.

## Approximate index/search captures (2026-10-07)

These contracts are investigative, not implemented or registered as passing
emulator cases. `vector-index-probe.sql`, `vector-index-ddl.cases.json` (18)
and `vector-search-contracts.cases.json` (14) reproduce in a 33-case oracle
repeat against 17.0.5005.3.

Enable PREVIEW_FEATURES in a separate batch before CREATE VECTOR INDEX:
parsing occurs before a same-batch configuration change can enable the syntax.
Keep index creation as a compared step; an ignored setup error would otherwise
make the following search test a different condition. Both the inner TABLE
alias and an outer result alias are accepted.

CREATE VECTOR INDEX supports cosine, euclidean and dot metrics and DiskANN.
Empty tables and one-row tables succeed, as do NULL and zero-vector rows.
A single four-byte INT clustered primary key is required (42217); a non-vector
column raises 42215. A second index on the same vector column raises 42230.
ALTER INDEX DISABLE/REBUILD raises 42250. Table DML raises 42231, TRUNCATE
raises 42232, and dropping the index restores DML. The catalog exposes type 8
VECTOR and DiskANN/COSINE; the three-row probe records build parameters
StartId=2, L=48, M=8 and R=48. These parameters are evidence for that fixture,
not universal build constants.

VECTOR_SEARCH requires an index with a matching metric (42227). TOP_N=0 and
a NULL query vector yield empty results; a large TOP_N returns the available
rows. Negative TOP_N is syntax error 102, NULL TOP_N is error 1060. The
three-row cosine result includes 0.2928932309150696, Euclidean includes
1.4142135381698608, and dot preserves negative zero. These simple results
do not yet establish the search kernel or approximate graph behavior.

The newer [CREATE VECTOR INDEX documentation](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql?view=sql-server-ver17)
and [VECTOR_SEARCH documentation](https://learn.microsoft.com/en-us/sql/t-sql/functions/vector-search-transact-sql?view=sql-server-ver17)
cover evolving Azure capabilities. Do not infer their current index format,
minimum-row requirements, DML support or scan fallback for this pinned server.
Our oracle rejects SELECT TOP WITH APPROXIMATE and the
ALLOW_STALE_VECTOR_INDEX database-scoped configuration.
