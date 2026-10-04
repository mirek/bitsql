# JSON functions, paths, aggregates and FOR JSON (SQL Server 2025)

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

## Not emulated

The json data type (`CAST(x AS json)`, RETURNING json, json columns): the
captures show it on the wire as varchar(max) with collation
Latin1_General_100_BIN2_UTF8 and flags 33; bitsql raises `Emulator: the
json data type is not supported` (never 243/2715). CLR arguments (13666).
