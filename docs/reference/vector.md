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

These contracts are investigative, not registered as passing emulator cases.
The parser now represents CREATE VECTOR INDEX and VECTOR_SEARCH explicitly;
construction and execution still raise unsupported errors. `vector-index-probe.sql`, `vector-index-ddl.cases.json` (18)
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

### Expanded grammar and graph evidence (2026-10-07)

Another 77 investigative cases were captured and repeated: `vector-index-contexts`
(20), `vector-search-graph` (15), `vector-index-grammar` (25),
`vector-search-grammar` (16), and `vector-graph-internal.sql` (1). Together with
the earlier 33, these establish 110 oracle index/search cases, not implemented
feature coverage. The grammar accepts metric/type case and trailing spaces,
N-prefixed literals and MAXDOP; vector options and argument ordering have their
own diagnostics. VECTOR_SEARCH has distinct source and result aliases: source
columns bind through the TABLE alias, while distance binds through the outer
alias. Query dimension mismatch is reported after result metadata.

The 20-row cosine fixture demonstrably differs from exact nearest-neighbor
scanning. `vector-graph-internal.sql` records its actual graph edges by reading
only the isolated fixture's allocated internal-table pages with DBCC PAGE.
The output strips page numbers, object IDs and memory addresses. Two independent
builds produced identical edges. Nodes 3, 6 and 7 have no incoming edges in this
fixture; a scan fallback would hide observable approximate-search behavior.

The isolated fixture's cached generated build SQL establishes the following
algorithm structure (the internal query has no XML plan in this capture):

- Choose a start row nearest VECTOR_AVERAGE of a repeatable non-NULL source
  sample. StartId is the primary-key value, not a row ordinal.
- Seed the graph with an all-pairs neighborhood over the first batch in key
  order plus the start row. The initial batch limit is 256, adjusted down when
  a smaller page/DOP least common multiple permits it.
- Prune distance-ordered candidates with the internal diskannprune aggregate,
  with maximum degree 48. Later batches search the existing graph with L=48,
  M=8 before pruning; this is not generic randomly initialized Vamana.
- Add reciprocal edges from later batches to prior rows. Accumulate pending
  edges until 56 bytes, then reprune the merged neighbors. The seed pruned
  buffer reserves 192 bytes, corresponding to 48 four-byte keys.

The pruning prototype matches 18/20 and 94/100 complete ordered neighbor lists.
Its two alpha passes (1 and float32 1.2), float32 occlusion ratios and zero-distance
handling explain the non-tied edges; candidate ordering for equal distances
remains unresolved. Using captured SQL sort order resolves some of the remaining
lists, showing why a stable primary-key tie breaker cannot be assumed. The
100-row source 83 also differs beyond simple candidate ties; pruning is still
a hypothesis requiring further oracle evidence.
These findings guide implementation; they do not justify claiming a working
index. Ordinary SQL cannot call diskannprune (195), including with QUERYTRACEON
8744. No server-wide trace flag or configuration was changed for these probes.

The 500-row page probe distinguishes pruned neighbors from pending reciprocal
neighbors. Search must traverse both: omitting pending neighbors loses rows
492–494 from the captured top ten. A bounded frontier of 48 over the captured
actual graph reproduces the existing 20-, 100- and 500-row cosine results;
this alone does not establish every search parameter.

Build-time M=8 has an observable role: expanding up to eight frontier candidates
together, then pruning the final frontier plus visited candidates, reproduces
240 of 243 newly inserted neighbor lists in the 500-row prototype. Expanding
one candidate at a time loses several distant build edges. The complete
prototype matches 476/500 neighbor sets but only 334 ordered lists; reciprocal
pending order and the seed/pruning differences remain open. A MAXDOP=1 repeat
of the 100-row oracle graph produced the same edges as the default build.
These larger graph probes remain scratch investigation, not registered passing
emulator tests.

A separate 257-row seed-only probe matches 238 complete prototype neighbor
lists. Substituting that captured seed into the 500-row build prototype raises
agreement to 496/500 neighbor sets and 241/243 newly inserted lists. The two
remaining new-row differences (sources 375 and 397) include candidates already
present in both the visited set and final frontier; they isolate a pruning
nuance rather than a missing search traversal. Sweeping nearby frontier and
expansion widths makes L=48/M=8 the best observed build match, consistent with
the captured generated query. The positional-resumption finding below subsequently resolves these pruning
differences. Candidate tie ordering and pending-edge ordering remain open.


### Verified pruning core (2026-10-07)

`vector-pruning.cases.json` contains 48 independently repeated fixtures for
cosine, Euclidean and dot metrics. Its normalized graph-page results provide
1,476 ordered neighbor lists. `scripts/gen-vector-pruning-tests.py` generates
pure storage-core tests directly from those captures and their input vectors;
all 48 tests pass. The fixtures include signed random components, dimensions
3–64, up to 96 source rows, 76 Euclidean lists reaching degree 48, identical
and zero vectors, single-row graphs, and INT minimum/maximum/zero keys.

Delta reduction of the 100-row discrepancy leaves only keys 8, 13, 39, 41 and
83. For source 83, distance order is 39, 41, 13, 8. The first alpha pass selects
39 and 13; the second selects 41 and 8. Eagerly applying newly selected 41 to
all later candidates wrongly removes 8. SQL Server resumes each candidate's
occlusion scan at its saved **candidate position**. It does not revisit newly
selected neighbors before that position. Removing any of 13, 39 or 41 removes
the discrepancy (`resume-without-*` captures).

`store/vector_prune.mbt` now implements this resumption rule with float32 ratios,
alpha passes 1 and float32 1.2, explicit zero-distance occlusion, and degree 48.
All three metrics use the ratio rule on their captured scalar distances. The
inner-product mask rule in the public [DiskANN implementation](https://github.com/microsoft/DiskANN/blob/main/diskann/src/graph/config/mod.rs) does not reproduce
this SQL Server build's dot graphs. This is oracle-derived behavior, not an
assumption that SQL Server embeds the current public library unchanged.

With the captured 257-row seed, the corrected 500-row build prototype matches
all 243 later-row neighbor lists and all 500 neighbor sets. Pending reciprocal
ordering still differs. The new core function accepts already ordered candidates;
it does not invent a primary-key tie breaker. A separate tie reduction leaves
seven source rows: six candidates change tie order, while removing any one of
four other candidates restores input order. SQL candidate sorting remains under
investigation. No CREATE VECTOR INDEX execution, graph builder, or VECTOR_SEARCH
execution is enabled by this pruning-only checkpoint.

### Verified traversal core (2026-10-07)

The actual Vector Index Seek plan exposes query-time parameters distinct from
build-time L=48/M=8: `L = GREATEST(5, TOP_N * 3 / 2)` and
`M = GREATEST(4, L / 6)`, using integer arithmetic. A variable TOP_N retains
those scalar expressions in the plan. TOP_N values 0, 1, 2, 3, 5, 7, 9, 10,
11, 16, 31, 48, 100, 101 and 1000 confirmed the boundaries. In particular,
TOP_N=10 uses L=15/M=4, not the build parameters.

`vector-search-traversal.cases.json` captures each graph and its search results
in the same database. Twelve seeded fixtures cover all three metrics, dimensions
3/8/16, signed primary keys, 20–500 rows, random/self/zero queries, and nine
TOP_N values from 0 to 1000. The graph dump includes pending reciprocal edges.
The generator derives 12 pure-core tests containing 324 searches: 252 compare
exact keys and distances; 72 all-tied cosine/dot zero-query results compare
captured count and distances plus distinct, valid source keys. No exact-scan
fallback is used. Starting at StartId, traversal expands the nearest M unvisited
frontier nodes together, merges their neighbors, retains the nearest L, and
repeats until no frontier node remains unvisited. Distances are cached.

An independent rebuild repeated every non-tied search result. Six larger graph
dumps changed, and six all-tied selections in cosine-3-500 changed their keys.
Consequently these raw graph captures are investigative fixtures, not a claim
that graph bytes or tied selections reproduce across builds. The component
uses primary-key order for equal distances. This does not resolve the separate
builder candidate-sort contract, where tie order changes non-tied graph edges.
Mixed tied/non-tied exploration needs further capture coverage. Graph
construction and SQL binding/execution remain unfinished; integration must
also retain the key lookup with the index rather than rebuilding it per query.
