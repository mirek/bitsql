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

## Not emulated

DATALENGTH of json values retaining mutation allocations, CLR arguments
(13666; hierarchyid/geometry/geography/vector are 50100, and
`geometry::Point(...)` static method calls do not parse).

### Native binary construction sizes (2026-10-06)

`sql2025/json-binary-size.cases.json` and `json-binary-boundaries.cases.json`
provide 236 captured sizes and canonical strings. The implementation matches
all 236 with the following inferred accounting. This supports DATALENGTH of
fresh native JSON values; it is not a claim to serialize SQL Server's format:

- Start with 18 bytes. Empty containers contribute zero additional bytes;
  nonempty arrays add 4 + 4n, nonempty objects add 4 + 6n, plus child payloads.
- Property names are shared across the entire document, case-sensitively. If
  there are any, add 4 + 8k plus the string payload of each distinct key.
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
for `$`: a modified 70-byte value rebuilds in 63 bytes. Modified values currently
retain explicitly unknown storage provenance, so their DATALENGTH raises an
Emulator error instead of reporting a freshly rebuilt size. Mutation allocation
and the modify method remain unfinished.

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
