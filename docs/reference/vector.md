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
eight-byte header; it is not implemented yet. Captures also retain additional
errors after failed declarations. `VECTOR_DISTANCE` advertises 3–4 arguments
in error 189, but all captured four-argument calls fail with 174 state 6.
Nonempty calls outside that range emit both errors. Batch behavior is covered;
stored-module diagnostic sequencing needs more captures. Embedding generation,
external models, approximate vector indexes/search and remaining conversion,
collation, aggregate and operator contexts are not complete.

2026-10-06: `vector-float16`, `vector-float16-values` and
`vector-float16-distances` add evidence for the next implementation stage.
SQL Server rejects both NORM and NORMALIZE on float16 with compile-time 42246,
including typed NULL. Mixed float32/float16 conversions fail at compilation
with 42238, while mixed-base DISTANCE raises 42243 after result metadata.
Float16 input first rounds to binary32, then binary16 (the near-midpoint
values in `vector-float16-values` distinguish direct binary16 rounding).
Half overflow is 42241 state 2; overflow before the half conversion is state 1.
Half columns expose scale 1 and retain readable data after PREVIEW_FEATURES is
turned off; only new float16 declarations are rejected with 195. These captures
are not registered as passing until float16 is implemented. Container release
validation must include the vector rounding corpus on ARM64 as well as amd64.

The 288 float16 distance pairs also distinguish its reduction kernel: a
prototype using the two-register cosine layout for **all three** float16
metrics matches every captured result. Reusing the four-register float32
dot/Euclidean layout differs on 26 dot and 12 Euclidean results. This is
oracle-derived evidence for the next implementation, not a claim that the
float16 path is already shipped.
