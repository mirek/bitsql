# JSON functions, paths, aggregates, FOR JSON and the json type (SQL Server 2025)

Rules distilled from captures on 17.0.5005.3: `harness/corpus/json3/*.sql`
(2026-10-04), msduck `json-advanced-path`, `json-extraction-wildcard`,
`json-extraction-boundaries`, `isjson-depth`, `unicode-json-storage`,
`json-aggregates`, `json-constructors`, `gaps-json_string`. Code:
`src/core/json` (paths, scanning, selection), `bind/for_json.mbt`,
`bind/json_agg.mbt`, `bind/fn_json2.mbt`, `exec/for_json.mbt`,
`exec/json_agg.mbt`, `session/precheck_json.mbt`. JSON_OBJECT / JSON_ARRAY /
JSON_MODIFY text rules are in [analytic.md](analytic.md).

## Path grammar and 13607 states

`[append] [lax|strict] $ accessor*`; `append` only for JSON_MODIFY.
Whitespace (space, tab, CR, LF) may surround every token: `' $ . "a" '`,
`$.a [0]`, `$[ 1 ]`, `strict$.a` all work. Accessors: `.key` (unquoted keys
are ASCII words `[A-Za-z_][A-Za-z0-9_]*`), `."quoted"`, `.*`, `[n]`, `[*]`,
`[a to b]`. `[n to n]` is the index `[n]` (also for JSON_MODIFY and OPENJSON).

| State | When | Examples (position) |
| --- | --- | --- |
| 14 | a known token in the wrong place (`$ . [ ] * ,`, a number, a quoted string, a keyword `lax strict append to last`) or the end of the path | `''` (0), `$.` (2), `$ 1` (2), `$.a]`, `$.$a`, `$[]`, `$[0 to ]`, `$[0 to 1 to 2]` (the second `to`), `$[*,1]`, `strict append $.a` (7) |
| 22 | an unknown word or symbol outside brackets | `x` (0), `strictx $` (0), `$a` (1), `$.a b` (4), `$.a#`, `$.a-b`, `$.ä` |
| 21 | an unknown word or symbol inside brackets | `$[a]`, `$[-1 to 0]`, `$[0 TO 0]` (`TO` is case-sensitive), `$[0 t]`, `$[1 to2]`, `$[lastx]` (at `l`), `$[last-1]` (at `-`) |
| 15 | a number immediately followed by a word character | `$[0to0]` (3), `$[0x]`, `$.1a` (3) |
| 16 | the index overflows a 32-bit unsigned accumulator (checked as "the value decreased") | `$[4294967297]` fails at its 10th digit, `$[99999999999]` at the 11th, `$[9999999999]` is accepted (wraps, matches nothing) |
| 17 | a bad escape in a quoted key | `$."a\x"` |
| 20 | an unterminated quoted key | `$."a` (4, `.` = end) |

After `.*` or a quoted key, an adjacent word character is 14 (`$.*x`,
`$."a"x`); after `]` it is 22 (`$[0]x`).

Advanced accessors that SQL Server parses but rejects, 13660 (severity 16,
compile time for constants, run time for variables):

- state 1 "Reversed indexing not yet supported…": raised as soon as the
  range end is read (`$[2 to 1` without `]`).
- state 2 "Last operator…": when `last` is followed by `,` or `to`, or at
  `]` of a non-list (`$[last,0]` 2, `$[0 to last]` 2).
- state 5 "Comma operator…": at `]` of a list (`$[0,last]` 5, `$[0,1]x` 5).
- JSON_MODIFY with `[*]`, `.*` or `[a to b]` (a < b): state 4 "JsonModify
  not yet supported for advanced JSON array accessors."
- OPENJSON's root path with a multi-value accessor: state 2 "OpenJson with
  default schema not yet supported for advanced JSON array accessors." (WITH
  column paths accept them: several values give NULL).

## Selecting values

Single-value paths stream: the text is read only up to the selected value
(`[1,x]` with `$[0]` is 1). A miss:

- a step of the wrong kind stops at once (`[1,2` with `$.x` is NULL);
- a member or index missing from a container leaves that container
  scanned; for the root container the text after it is validated too
  (`{"a":1} x` with `$.missing` is 13609 at 8, `{"a":{"b":1},"c":x}` with
  `$.a.missing` is NULL).

Multi-value paths (`.*`, `[*]`, `[a to b]`): the prefix before the first such
accessor streams as above; from there every candidate container is scanned
entirely (`[{"a":1},{"a":2,"b":x}]` with `$[*].a` is 13609 at 20) but nothing
after it (`{"a":[1,2],"b":x}` with `$.a[0 to 1]` is NULL). Then:

- a JSON null among the selected values ends the search: NULL, even under
  strict and even before malformed text (`[1,null,x]` `$[*]` is NULL);
- inside a multi-value accessor, missing members and wrong kinds are
  skipped even under strict (`strict $[*].a` over `[{"b":0},{"a":2}]` is 2);
- a strict range running past the end of a non-empty array is 13659 "Index
  {last index} provided at position {position after ]} is not within the
  array of size {range end}." (`[1,2,3]` `strict $[5 to 7]`: index 2,
  position 7, size 7); an empty array is 13608;
- one value: JSON_VALUE returns a scalar, JSON_QUERY a container; the wrong
  kind is NULL (lax) or 13608 (strict, not 13623/13624);
- no value: NULL / 13608; several values: NULL / 13608 (JSON_VALUE) or
  13624 (JSON_QUERY).

JSON_QUERY of a JSON null is NULL also under strict (`[null]`, `strict
$[0]`).

## Error states and batch abort

| Error | literal / nvarchar(n) / varchar(n) | nvarchar(max) / varchar(max) |
| --- | --- | --- |
| 13609 malformed text (JSON_VALUE/QUERY) | 1 | 2 |
| 13608 strict miss | 1 | 2 |
| 13623 strict scalar wanted | 2 | 1 |
| 13624 strict container wanted (one value) | 2 | 1 |
| 13624 several values | 3 | 4 |

The state follows the document's type, not compile vs run time
(`UPPER(N'x')` is state 1 at run time). Constant arguments are evaluated
while compiling (ERROR + DONE 253, no COLMETADATA). With a max document a
root scalar is read before failing (`'1'` fails at position 1, `.` = end;
a literal at position 0). Other states: JSON_MODIFY 13608/2, 13609/7,
13621/1 (append strict to a non-array); OPENJSON 13608/3, 13609/4; 13625/1;
13659/1; 13606/1.

Every JSON run-time error (136xx, and the NULL-path 8116 state 8) ends the
batch: the next statement does not run, and in an RPC the ERROR is followed
directly by DONEPROC (no DONEINPROC, no RETURNSTATUS). TRY/CATCH catches
them. `JSON_VALUE(x, NULL)` (bare NULL) is 8116 state 1 at compile time;
JSON_QUERY and a typed NULL path are 8116 state 8 at run time, checked
before a NULL document.

## Nesting limit (13606)

Lazy, like the scanner: a container opened inside 129 containers fails at
once; a scalar or member name inside 129 containers fails only once it is
complete (`[`×129 + `"a` unterminated is ISJSON 0, `[`×129 + `1,` is 13606,
`[`×128 + `{"a"` is 13606, `[`×129 + `x` is 0). ISJSON raises 13606 instead
of returning 0; JSON_VALUE with a wrong-kind first step never sees it.

## ISJSON and JSON_PATH_EXISTS

- `ISJSON(x, VALUE|ARRAY|OBJECT|SCALAR)`: a bare or bracketed word, any
  case. SCALAR is a string or number (not true/false/null); VALUE any value;
  whitespace around the value is allowed. An unknown word is the parser's
  155 "'NUMBER' is not a recognized isjson option."; a string, NULL or
  variable is 1023 "Invalid parameter 2 specified for isjson." for the whole
  batch. text/ntext are 8116.
- `JSON_PATH_EXISTS(doc, path)`: int, NULL for a NULL document; 1 when the
  path reaches a value (a JSON null counts), 0 when it does not, when the
  root is a scalar, or when the document is not valid JSON anywhere
  (`{"a":1,"b":x}` with `$.a` is 0). 13606 and path errors still raise.
  Non-character arguments are 8116 state 1 ("json_path_exists"); a NULL path
  8116 state 8 at run time.

## JSON text embedded as is

FOR JSON columns and JSON_OBJECT / JSON_ARRAY / JSON_MODIFY / JSON aggregate
values embed JSON text raw: JSON_QUERY, JSON_MODIFY, JSON_OBJECT,
JSON_ARRAY, JSON_ARRAYAGG, JSON_OBJECTAGG and FOR JSON subqueries with the
array wrapper, also through derived tables, CTEs and views. A variable, a
WITHOUT_ARRAY_WRAPPER subquery and JSON_VALUE are strings.

## FOR JSON AUTO

- One level per FROM source in the order of its first selected column
  (`SELECT b.x, a.id` nests `a` under `b`). Table-valued functions (and
  set operations) do not form levels: their columns stay flat.
- An expression belongs to the level of the column before it; leading
  expressions belong to the first level. Expressions do not take part in
  grouping.
- A row joins the previous object of a level when that level's source
  columns equal the previous row's (consecutive rows only, compared under the
  column collation, so `'a'` and `'A'` merge and the first spelling stays);
  the deepest level never merges. Child arrays are named by alias, else by
  the name as written (`dbo.b`), and follow the level's own columns.
- An outer-join child of only NULLs is `{}` (`{"x":null}` with
  INCLUDE_NULL_VALUES). Dotted aliases stay flat in AUTO.
- 13600 (AUTO without a table: no FROM, or only table-valued functions) and
  13620 (ROOT with WITHOUT_ARRAY_WRAPPER) reject the whole batch before it
  runs, also inside subqueries; 13605 (unnamed column) is a statement error.

## JSON_ARRAYAGG / JSON_OBJECTAGG

- nvarchar(max), result flags 1 (33 through a subquery, 9 through a view).
  No input rows: NULL; a group of only NULL values is `[]` / `{}` under
  ABSENT ON NULL. Defaults: JSON_ARRAYAGG ABSENT ON NULL, JSON_OBJECTAGG
  NULL ON NULL; no 8153 warning. A NULL key is 13638 ("json_object").
  Duplicate keys are kept. Values format like JSON_OBJECT's.
- `JSON_ARRAYAGG(v ORDER BY ...)` orders the array; its order takes part in
  8711 with STRING_AGG. A WITHIN GROUP clause on JSON_ARRAYAGG is accepted
  and ignored. Unordered JSON aggregates of a scope follow the scope's
  ordered aggregate (`JSON_OBJECTAGG(k:id)` next to `JSON_ARRAYAGG(k ORDER
  BY v DESC)` lists keys by v DESC); otherwise scan order.
- `OVER (...)` gives running arrays/objects (default RANGE frame).
- Errors: `JSON_OBJECTAGG(k, v)` / two pairs / `JSON_ARRAYAGG()` 174;
  `JSON_ARRAYAGG(DISTINCT v)` 313 state 2; `JSON_ARRAYAGG(k:v)` 102 state 10
  near the name; both NULL clauses 102 state 20 near the name; RETURNING
  other than json 102 state 19 (OBJECTAGG's message reads "near 'RETURNING.
  Supported Syntax is RETURNING JSON'"); ORDER BY in OBJECTAGG or after
  RETURNING 156; WITHIN GROUP on OBJECTAGG 102; `ORDER BY 1` 5308; nested
  aggregate 130.

## The json data type (SQL Server 2025)

Captures: `harness/corpus/json4/*.sql` (2026-10-04), msduck
`json-constructors` #016-#020, `json-aggregates` #025/#037/#038/#055/#069/
#102. Code: `types/json_type.mbt` (parser, normalizer, conversions),
`bind/xml_methods.mbt` (`json_arg_check`, comparison checks shared with
xml), `exec/fn_json2.mbt`, `exec/json_agg.mbt`.

### Values and the wire

- A json value is kept as its canonical text (`Value::String`). Clients
  (TDS 7.4) receive varchar(max) with collation
  Latin1_General_100_BIN2_UTF8 (flags byte 0x60, UTF-8 data); column flags
  as for any other type (33 for CAST results, 9 for a nullable column, no
  fCaseSen). sp_describe_first_result_set /
  sys.dm_exec_describe_first_result_set report `varchar(max)` (167), that
  collation and is_case_sensitive 1, never `json`.
- Catalog: sys.types and sys.columns system_type_id = user_type_id = 244,
  max_length -1, precision/scale 0, collation NULL; INFORMATION_SCHEMA
  DATA_TYPE `json`, CHARACTER_MAXIMUM_LENGTH and OCTET_LENGTH -1, no
  collation/character set; COLUMNPROPERTY Precision -1, COL_LENGTH -1;
  TYPE_ID('json') 244; sp_help Type `json`, Length -1; **sp_columns leaves
  json columns out**; a json column sets sys.tables.lob_data_space_id.
- `json(100)` is 2716 in declarations and 291 "CAST or CONVERT: invalid
  attributes specified for type 'json'" in CAST; `RETURNING json(n)` and
  `RETURNING json(max)` are accepted.
- DATALENGTH is the size of the internal binary format (43 for
  `{"a":1}`): emulator error.

### Parsing character data (CAST, assignment, INSERT/UPDATE, arguments)

- The root must be an object or an array. Whitespace is space, tab, LF, CR
  only (NBSP is an error). Output has no whitespace.
- Duplicate member names keep the **first** member (also nested); keys are
  compared exactly (`a` and `A` differ). Member order is kept.
- Strings are decoded and re-escaped: `"` and `\`, `\b \f \n \r \t`,
  other characters below U+0020 as `\u00XX` with upper-case hex, everything
  else raw (`/`, DEL, U+0080, U+2028, non-BMP). A lone surrogate, raw or as
  a `\u` escape, becomes U+FFFD; an escaped pair becomes the character.
- Numbers without an exponent and with at most 38 significant digits (a
  lone leading `0` does not count) keep their text, scale included (`1.50`,
  `0.00`); the sign of a zero is dropped (`-0` → `0`, `-0.0` → `0.0`).
  Numbers with an exponent, or with more digits and a fraction, go through
  float to decimal(38,10): `1e2` → `100.0000000000`, `1e28` →
  `9999999999999999583119736832.0000000000`, `1e-11` → `0.0000000000`.
  More than 28 integer digits that way is 1007 state 5 "The number '1e29'
  is out of the range for numeric representation (maximum precision 38)."
  (the number as written); an integer of 39+ digits is 1007 state 3.
- Malformed text is 13609 **state 9** "JSON text is not properly formatted.
  Unexpected character 'c' is found at position N." where N is the 0-based
  **UTF-8 byte offset** and `c` that byte read as Latin-1 (`Â` for NBSP,
  `ï` for a lone surrogate's EF BF BD, `.` at the end). Any error inside a
  string (unterminated, bad escape, raw control character) points at its
  opening quote; malformed numbers (`-`, `1.`, `1e`, `01`) and literals
  (`tru`) at their first character; a scalar root at its first character.
- Nesting: 128 containers are fine, the 129th is 13645 "Nested level of
  JSON document exceeds limit 128.".
- Conversion errors happen at run time (after COLMETADATA) and end the
  batch; TRY_CAST/TRY_CONVERT give NULL for 13609, 13645, 13639 and 13640
  but still raise 1007. A bad procedure argument is 13609 at line 0 and
  ends the batch (DONE 253, no DONEPROC).

### Conversions and operators

- Implicit: character types → json only; json → nothing (257 state 3 to
  character types, also PRINT and CONCAT/CONCAT_WS, which name varchar when
  no argument is Unicode; 206 to every other type, also int → json).
  ntext/text ↔ json and everything non-character is 529 state 1. json has
  the highest precedence: CASE, COALESCE, ISNULL, IIF, CHOOSE and UNION ALL
  with character data give json (ISNULL stays nullable); int, sql_variant,
  xml, datetime2, uniqueidentifier or varbinary with json are 206 ("int is
  incompatible with json").
- json → char/varchar/nchar/nvarchar: the text; 13640 "Conversion of one
  or more characters from the JSON instance to target codepage 1252 will
  result in data loss. Choose a different target collation or use
  nvarchar." when a character has no mapping (best fit applies: U+0100 →
  `A`); then 13639 "Target string size is too small to represent the JSON
  instance." when it does not fit (no truncation); fixed types are padded.
- Not comparable: json = json, <>, NULLIF, join conditions 13636 state 1
  "The JSON data type cannot be compared or sorted, except when using the
  IS NULL operator."; ORDER BY, GROUP BY, window PARTITION BY / ORDER BY
  13636 state 2; DISTINCT 421; UNION / INTERSECT / EXCEPT 5335; json with
  another type (=, >, IN, simple CASE) 402; LIKE 8116; MIN/MAX 8117 state 1,
  COUNT(DISTINCT) 8117 state 2 (COUNT works); `+` 402 / 8117; unary minus
  8117. These are batch compile errors.
- Built-ins: 8116 state 1 for string functions (LEN, UPPER, SUBSTRING,
  REPLACE, ISNUMERIC, TRIM named "Trim", STRING_AGG, HASHBYTES argument 2),
  8116 state 4 for GREATEST/LEAST/CHECKSUM, SQL_VARIANT_PROPERTY 206. Index
  keys: CREATE INDEX 1978 state 3 "... invalid for use as a key column in
  an index or statistics.", a PRIMARY KEY 1919 + 1750.
- ALTER COLUMN nvarchar → json validates every row (13609 + 3621); json →
  nvarchar(max) is 257 without 3621.

### JSON functions over json values

- JSON_VALUE: nvarchar(4000) as usual. JSON_QUERY and JSON_MODIFY of a
  json document return json; ISJSON, JSON_PATH_EXISTS and OPENJSON read the
  normalized text.
- Error states differ for json documents: 13608 state 5 (JSON_VALUE,
  JSON_QUERY, JSON_MODIFY), OPENJSON path 13608 state 7, WITH column 13608
  state 8, 13623/13624 state 2, several values under strict 13623 (VALUE) /
  13624 (QUERY) state 2, a strict range past the end 13608 state 5 (not
  13659), append to a non-array 13621 state 2, a strict OPENJSON path to a
  scalar 13611 state 3 (state 1 for character documents).
- JSON_MODIFY of a json document re-normalizes the result: a float value
  becomes decimal(38,10) (`1e2` → `100.0000000000`; too large is 8115 state
  18). JSON_MODIFY of character text with a json new value is 8116 for
  argument 3.
- FOR JSON, JSON_OBJECT, JSON_ARRAY and the JSON aggregates embed json
  values raw; a json argument makes JSON_OBJECT / JSON_ARRAY /
  JSON_ARRAYAGG / JSON_OBJECTAGG return json even without RETURNING JSON.
- OPENJSON WITH (c json ...): with AS JSON a container is kept, a scalar is
  NULL; without it, over character text every scalar value is parsed as json
  (a number fails with 13609), over a json document only string values are
  (other scalars and containers are NULL).

### RETURNING JSON

- The constructors and aggregates return json: the built text is parsed
  and normalized (first duplicate key kept, `/` unescaped, control
  characters `\u00XX`). Float values become decimal(38,10) (1.5 →
  `1.5000000000`, real too); one that does not fit is 8115 state 19
  "Arithmetic overflow error converting float to data type numeric." in the
  constructors, while the aggregates format the float as text first and
  fail with 1007 state 5 "The number '2.000000000000000e+028' ...". money
  keeps four decimals, bit is true/false, dates and binary as for
  JSON_OBJECT.
- Windowed JSON_ARRAYAGG / JSON_OBJECTAGG stay nvarchar(max) even with
  RETURNING JSON. A json-typed aggregate column reports flags 33 and
  is_computed_column 1 (other aggregates 0).
- Syntax: another type after RETURNING is 102 state 19 ("near 'RETURNING.
  Supported Syntax is RETURNING JSON'" for JSON_OBJECT / JSON_OBJECTAGG,
  "near 'RETURNING'" for JSON_ARRAY / JSON_ARRAYAGG); `JSON_ARRAY(RETURNING
  JSON)` is 102 near 'JSON'.

### Native binary construction sizes (2026-10-06)

`sql2025/json-binary-size.cases.json` and `json-binary-boundaries.cases.json`
provide 236 captured sizes and canonical strings. The implementation matches
all 236 with the following narrow-format accounting. Large-format extensions
are documented below. This supports DATALENGTH of
fresh native JSON values; it is not a claim to serialize SQL Server's format:

- Start with 18 bytes. Empty containers contribute zero additional bytes;
  nonempty arrays add 4 + 4n, nonempty objects add 4 + 6n, plus child payloads.
- Property names are shared across the entire document, case-sensitively. If
  there are any, add 4 + 8k plus the string payload of each distinct key.
  Above 1,024 keys, the dictionary also has a two-byte index per key.
- Empty strings are inline. A nonempty string costs its UTF-8 byte length,
  a one-byte tag, and a base-128 variable-length length field. String **values**
  are not deduplicated, and do not share payloads with property names.
- Null and booleans are inline, as are integers from -2^29 through 2^29 - 1.
  Other signed 64-bit integers add nine bytes. Larger integers and decimal
  values add five bytes plus four per 32-bit limb of the absolute unscaled
  coefficient, with at least one limb. Decimal scale remains significant.

The canonical representation suffices for these construction captures,
including duplicate member names keeping the first value. It does not suffice
after mutation: `sql2025/json-storage-mutation.sql` verifies that changing
`{"a":"abcdefgh","b":1}` to `{"a":"x","b":1}` with `.modify()` retains
70 bytes, while a text round trip rebuilds it in 63 bytes. Growing that string
to sixteen characters increases allocated size to 88 (rebuilt: 78); replacing
an out-of-line integer with an inline one retains its allocation. Deleting a
property also retains storage. Both column and variable mutation work on the
oracle. Large property dictionaries and precise allocation transitions still
need verification; native JSON needs storage state beyond canonical text.

Values now carry a `NativeJson` representation with canonical text and storage
provenance. Fresh construction computes size once; assignment and casts from
json to json preserve the value. `sql2025/json-constructed-storage.sql` verifies
variables, tables, constructors, aggregates, JSON_QUERY, OPENJSON and regex
result JSON. The older `json4/type-datalength.sql` also passes.

`sql2025/json-function-storage.sql` shows JSON_MODIFY retaining allocation just
like the native modify method. JSON_QUERY rebuilds its selected result, even
for `$`: a modified 70-byte value rebuilds in 63 bytes. The allocator retains this state through JSON_MODIFY and native modify
statements.

`sql2025/json-mutation-column-allocation.cases.json` adds 37 mutation sequences,
all reproduced in a second oracle run. Shrinking a string does not reserve its
former length for later reuse: growing it again appends the new payload.
Deletion leaves reusable object slots and dictionary entries; reinserting the
same inline property can leave DATALENGTH unchanged. Array append grows capacity
in steps (a two-element inline array grows from 30 to 50 bytes for its third
element, stays at 50 for its fourth, then grows to 86 for its fifth).

The parallel variable capture `json-mutation-allocation.cases.json` is
investigative evidence, **not a stable compatibility contract**: two sequences
dropped their connections, and some others raised internal LOB errors 22002 or
22020. The captured 22002 for `$[1]` did not recur on an independent run. A
127/128-byte string transition also produced error 596 and killed its session
in a probe. Do not encode these unstable errors as deterministic SQL behavior
or count the missing expectations as passes. Corresponding persisted-column
sequences completed normally.
Microsoft documents a native
[json modify method](https://learn.microsoft.com/en-us/sql/t-sql/data-types/json-data-type?view=sql-server-ver17#the-modify-method)
with in-place updates, so construction-only evidence must not be generalized
to modified storage without captures. JSON_CONTAINS and CREATE JSON INDEX are
also listed among the
[2025 JSON additions](https://learn.microsoft.com/en-us/sql/relational-databases/json/json-data-sql-server?view=sql-server-ver17#sql-server-2025-changes)
and remain part of the feature audit.

### Retained mutation storage and slot order (2026-10-06)

The implemented allocator matches the 839 captured transitions in
`sql2025/json-modify-allocation.cases.json`, `json-dictionary-allocation.cases.json`,
`json-allocation-growth.cases.json` and `json-allocation-sequences.cases.json`.
These include scalar/array/object replacement, shared/new keys, repeated
identical container replacement, capacity boundaries and mixed mutation chains.
The core has 303 generated storage tests: 236 construction tests plus 67
mutation sequences containing 669 operations, with immutable-copy assertions.

- Scalar payloads reuse their current bytes when the replacement fits;
  growing appends a new payload. Shrinking does not retain reusable capacity
  for a later growth. Replacing a container allocates fresh live payloads even
  when its visible text is unchanged; dead input storage is not copied.
- Containers retain spare slots. Growth adds `max(2, min(15, floor(6n/5)))`
  slots to capacity n and appends a new container payload. The old payload is
  retained. The property dictionary uses the same capacity growth; it expands
  in place only when it is the final payload, otherwise a new table is appended.
- Scalar property insertion registers its key before allocating the value.
  Container insertion clones its value first. This ordering can change whether
  the dictionary grows in place. Dictionary entries survive property deletion.
- Deletion leaves an empty property slot; insertion fills the first empty slot
  before appending. Preserve physical slot order when rendering native JSON.
  Text-only editing gets reinsertion order wrong. Evidence:
  `json-property-slots.sql` and mixed mutation sequences.
- `json-allocation-lifetime.sql` verifies 2,200 repeated container replacements
  retaining 22,064 bytes, copying a modified native value into another document,
  transaction rollback and independent variable copies. No compaction occurs
  in these captured sequences, including after the value exceeds inline size.
- A lax append targeting a deleted property leaves it deleted. A genuinely
  missing final property raises the captured 13656 state 8 feature-switch error
  on the pinned oracle, even with PREVIEW_FEATURES ON; text JSON still creates
  the array. Strict missing/deleted paths raise 13608 state 5, and strict append
  to JSON null raises 13621 state 2. Evidence: `json-tombstone-paths.cases.json`
  and `json-append-missing.cases.json` (variables, columns and both preview states).

This is an allocation model, not a serializer for native SQL Server pages.
Other JSON audit items and the large-storage edge cases below remain open.

### Large dictionaries and document-wide format (2026-10-06)

The seven registered case files `json-wide-storage`, `json-dictionary-index`,
`json-dictionary-lazy-index`, `json-wide-growth`, `json-wide-transitions`,
`json-global-wide-format` and `json-large-cardinality` cover 87 further cases.
All previously timed-out object constructions were captured with a 180-second
request timeout; the largest has 100,000 properties. No expected results were
inferred from timeouts. The core storage generator now includes 356 tests.

- Fresh dictionaries above 1,024 unique keys add a sorted index. In narrow
  format it uses two bytes per allocated key slot. After mutation creates the
  1,025th key in an existing spare slot, the index can remain absent until the
  next new-key insertion. Existing-key edits and deletion do not create it.
- Fresh arrays above 65,535 elements or dictionaries above 32,768 keys switch
  the whole document to wide format. All container/dictionary headers become
  six bytes; object entries become eight bytes; dictionary index entries
  become four bytes. Array entries and the non-index part of dictionary
  entries remain four and eight bytes respectively. Header/footer overhead
  remains 18 bytes. Nested arrays affect parents and siblings too.
- Array widening rebuilds the current live document before applying the
  operation. This removes dead storage and deleted slots; it is an exception
  to ordinary retained-allocation behavior. Read-only native page dumps
  confirmed the document header change and relocation of the rebuilt root;
  regression expectations come from the SQL captures above.
- Narrow mutable capacities are capped at 65,535 array elements and 32,767
  object/dictionary slots. Inserting a new key beyond that dictionary limit
  widens before mutation. Fresh construction can still hold 32,768 keys in
  narrow format, and editing an existing scalar need not widen it.

Further mutation cases remain investigative: `json-wide-mutation` and
`json-dictionary-wide-capacity` currently have five disagreements across 15
cases. Three involve conservative widening when cloning a small container
near a large dictionary's limit. The others capture oracle errors 13641
(resource limit after reusing a deleted slot) and 13643 (corrupted JSON after
multiple wide-container replacements). Do not encode corruption as a stable
contract without independent verification. These cases are not registered as
passing support and remain release requirements.

Follow-up evidence in `json-wide-preflight` shows that cloning even an empty
container into a narrow document with 32,767 dictionary keys widens it;
scalar replacement does not. At 32,766 keys, copying a two-element array does
not widen, so adding the source and destination element counts is the wrong
rule. `json-wide-empty-replacement` independently reproduces 13643 for both
variables and persisted columns: copying `[1]` over an empty container in a
wide document adds eight bytes (the narrow array size), DATALENGTH succeeds,
and character conversion raises 13643 state 8. Copying an object or scalar
into the same slot succeeds. Retain this error timing and source-format
provenance in the remaining audit; do not replace it with a guessed immediate
mutation error.

### Native modify statement contracts (2026-10-06)

`json-modify-method-contracts` and `json-modify-variable-flow` distinguish
`SET @j.modify(path, value)` from a JSON_MODIFY assignment. Successful variable
mutation sets @@ROWCOUNT to 1 and emits DONE CurCmd 193. A typed NULL path is a
successful no-op, although a NULL literal path is a binding error 8116. A NULL
target raises 5302 before path parsing, after earlier statements have run;
the uncaught error completes with CurCmd 253. Arity/type errors are detected
before earlier SELECT statements execute. TRY/CATCH observes a failed method
statement's zero-row completion. Assignment copies remain independent.

Column contracts include row expressions for both arguments, aliases with
OUTPUT, mixed SET clauses, duplicate targets (264), NULL targets (5302), and
unknown methods (258). The variable, UPDATE and MERGE forms are implemented.
`json-modify-contexts` also covers updatable views, transaction and statement
rollback, mixed setters and MERGE OUTPUT. Qualified setters such as
`t.j.modify(...)` are syntax error 102 near `modify`; the unqualified column
name is required. Mutator arguments bind even for an empty MERGE target.

`json-modify-types` covers 29 argument cases. A float exceeding decimal(38,10)
raises 8115 state 18, preserves the previous document and allows following
statements to run; NULL-target and malformed-path errors end the batch.
Typed NULL path variables are no-ops, while NULL values delete lax properties.
Typed int NULL cannot initialize a json variable/column (206); bare NULL can.

All 121 newly registered method cases pass the focused run, including the
37 persisted-column allocation sequences and the earlier storage-mutation
SQL file. The five adjacent JSON/NULL regression cases also pass (126 total).
The parser's 49 native column-method gaps are resolved. Shared large-storage
mutation discrepancies documented above still apply to native modify.

## Not emulated

Broader JSON index option/concurrency/internal-storage behavior remains under
audit (see below). CLR arguments remain unsupported
(13666; hierarchyid/geometry/geography/vector are 50100, and
`geometry::Point(...)` static method calls do not parse).

## JSON_CONTAINS (2026-10-06)

The pinned 17.0.5005.3 oracle requires native json targets; text targets fail
with 8116. Exact numeric, bit and string searches are accepted; native json
search values are rejected. String equality follows the search expression's
collation. Omitted paths behave like `$[*]` in the captured root shapes, while
explicit `$` does not search array elements. Missing selections return NULL;
resolved empty wildcards return zero. Strict wildcard navigation can return
NULL where lax navigation finds a match after a missing property. Only int
comparison modes are accepted: zero is equality, one is LIKE, and other values
raise 13692. Explicit NULL paths raise 8116 state 8 even for NULL documents;
NULL documents otherwise short-circuit malformed path strings and invalid
mode values. Typed NULL searches return zero for existing selections, whereas
bare NULL searches fail binding. These contracts are implemented. The dedicated
selection walker supports list/last accessors without changing the existing
extraction functions' unsupported-accessor errors. Strict ranges/lists return
NULL if any requested index is outside the array. Empty wildcards return zero,
whereas wholly out-of-bounds selections return NULL. `last to 0` over a nonempty
array can select an empty range and return zero. Equality ignores trailing
spaces; LIKE retains padding in fixed-width search patterns. Text/ntext are
invalid search and path argument types. Numeric matching compares exact decimal
values; bit search values only match JSON booleans.

Evidence: seven `sql2025/json-contains-*.cases.json` files (255 cases), covering
scalar calls, variables, table filters/updates, errors and TRY/CATCH. The focused
run passes all 308 cases including scoped preview completions and adjacent
vector/JSON regressions. JSON indexes and the shared storage gaps remain open.

## JSON indexes (2026-10-06)

`sql2025/json-index-contracts.cases.json` captures 26 initial contracts. JSON
indexes work with PREVIEW_FEATURES ON or OFF, report index type 9 / JSON, and
start at index_id 1216000. The oracle requires a clustered primary key (13672),
not merely a unique clustered index; non-json columns fail with 13680. Duplicate
index names yield 1913 state 3, and a second JSON index on one column yields
13681. Overlapping/duplicate paths yield 13683 state 1; wildcard paths yield
13683 state 2. Both ONLINE=ON and ONLINE=OFF fail with 153 state 35
on this pinned oracle. Repeated FILLFACTOR options
are accepted with the last value retained. DROP/recreate, DISABLE/REBUILD and
indexed document updates are implemented from these captures.

The 12 `sql2025/json-index-catalog-lifecycle` cases additionally capture
`sys.json_indexes` and `sys.index_columns`: JSON key_ordinal is zero and
optimize_for_array_search reflects its option. Two JSON columns receive
1216000/1216001; dropping the first while retaining the second then creating
a new index gives 1216002 (not the lowest free slot). Ordinary indexes do
not consume that range. Creation rolls back with its transaction. A JSON
index prevents dropping the primary key (3767 then 3727) and its document
column (5074 then 4922). Rename and explicit INDEX hints work; a disabled
index hint raises 315. These behaviors are implemented.

The 19 `sql2025/json-index-paths` cases capture `sys.json_index_paths`
(object_id int, index_id int, path varchar(8000) with UTF-8 BIN2 collation).
The catalog retains original whitespace, quoted keys and lax/strict prefixes;
the default stored path is `$`. Overlap checks operate on path meaning rather
than raw text: `$.a` overlaps `$."a".b`, but not `$.ab`. `$.a` and `$.A`
conflict in the captured default CI database; other database collations still
need verification. Literal array indexes are accepted; last/object wildcards
fail with 13683 state 3. Rebuilding with DROP_EXISTING replaces the path set.
These first three files contain 57 cases, verified on repeat oracle runs.
Their 58 parser disagreements are resolved.

The 18 validation cases additionally cover grammar, option diagnostics, and
missing columns/indexes (1911 state 7, DROP_EXISTING 13685 state 2). JSON index
syntax accepts one unsorted document column; INCLUDE/WHERE and UNIQUE forms
are rejected. IGNORE_DUP_KEY is 153 state 35. PAD_INDEX is accepted and is_padded
reflects it. Eight option/catalog cases show that JSON indexes have no partition
or statistics row under the base table; `json-index-statistics.sql` captures the
ordinary primary-key statistics row alongside them. Generated descriptors for
all three new views come from `catalog/view-descriptors-json-indexes.sql`.

The immutable store maintains concrete path-to-row entries from live native
JSON nodes, including containers and JSON nulls. Filtered index roots restrict
which paths are stored. Positive JSON_CONTAINS and JSON_PATH_EXISTS predicates
can seek a concrete prefix; the original predicate checks each candidate.
Uncovered paths fall back to a scan. Eight maintenance cases cover indexed
mutation, deleted/reinserted paths, bulk deletion, snapshots, disable/rebuild,
truncate, subset roots and Unicode. Two white-box checks compare indexed
execution with a forced scan and verify that the optimized execution does not
read the table through its scan source. All 152 focused cases pass.

This is not a completed audit of JSON indexes: value-based/range access,
broader options, collation-dependent overlap validation,
internal tables and storage, and concurrency/locking details still need captures
and implementation review. No container release is implied by this checkpoint.

### Native JSON_PATH_EXISTS and indexed errors (2026-10-06)

The 28 `sql2025/json-path-exists-native` cases distinguish native and text
inputs. Native inputs accept last/list accessors, treat a resolved empty
wildcard as existing, and return zero when strict traversal encounters a
missing branch or out-of-range list/range element. Text inputs reject last/list
accessors and ignore strict mode for existence testing, including ranges.
Native behavior uses the containment selection walker, testing for a resolved
selection rather than its cardinality.

For indexed document predicates, SQL Server validates literal malformed paths
before result metadata and earlier DECLARE completion. Variable paths and
unindexed column paths retain runtime error timing. Evidence also includes
`sql2025/json-index-query-errors.sql`. The planning check preserves this
boundary; runtime candidate pruning must not conceal path or comparison-mode
errors.

### Index options and disabled clustered keys (2026-10-06)

Thirty cases in `json-index-placement-alter`, `json-index-alter-options`,
`json-index-disabled-table` and `json-index-disabled-rebuild` establish the
following additional contracts. Trailing `ON filegroup` is a syntax error 156;
STATISTICS_NORECOMPUTE on CREATE is 153 state 35. DROP_EXISTING cannot convert
ordinary to JSON (13685 state 1) or JSON to ordinary (10682 state 2); changing
the indexed JSON column succeeds. Creating a JSON index on a view raises 13678.
ALTER SET lock options fail with 13688; OPTIMIZE_FOR_ARRAY_SEARCH in ALTER is
syntax error 155. REBUILD accepts FILLFACTOR, MAXDOP, PAGE compression and
ONLINE=OFF, but ONLINE=ON is 153 state 37. REORGANIZE succeeds.

Disabling the clustered primary key also disables dependent JSON indexes and
emits warning 3750. SELECT and DML fail before result metadata with 8655, while
TRUNCATE succeeds and retains disabled state. A batch containing primary-key
REBUILD followed by SELECT fails compilation before either runs. Rebuilding
only the primary key in a separate batch restores access, leaving the JSON
index disabled. Rebuilding only the JSON index while its clustered key is
disabled gives 1987; ALL REBUILD gives 8655 and leaves both disabled. These
captured behaviors are implemented. Wider dependencies (foreign keys, indexed
views), option combinations and concurrent lifecycle operations remain open.

### Internal index catalog captures, pending implementation (2026-10-06)

Seventeen investigative cases in `json-index-internal-catalog`,
`json-index-internal-details`, `json-index-internal-key-types` and
`catalog/view-descriptors-json-internal` capture the next open surface. Each
JSON index owns a `sys.internal_tables` row: internal_type 235,
JSON_INDEX_TABLE, parent_minor_id equal to its JSON index_id. Its internal
clustered index is named after the JSON index (id 1); a posting-column
nonclustered index has id 2. OPTIMIZE_FOR_ARRAY_SEARCH adds id 3,
`json_index_search_optimization_nci`. Internal columns hold the path, array
position, sql_variant scalar, status, overflow path/value, and one posting
column per clustered primary-key component. Their types and keys are captured,
not inferred from the public JSON index columns.

Internal partition row counts follow indexed scalar leaves (including JSON
null), excluding empty containers and duplicate object keys. The exact rules
for repeated values and retained disabled storage still need investigation.
PAGE compression is visible on the internal partitions. Disabling the JSON
index retains the clustered internal partition but removes its nonclustered
partitions. These captures are not registered as passing and do not close the
internal-storage or array-search implementation work.
