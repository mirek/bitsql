# text, ntext, image

Captured on SQL Server 2025 (`harness/corpus/conversion/lob-conversions`,
`lob-functions`, `lob-table`; msduck `concat-legacy-family`,
`charindex-patindex`, `compress-decompress`, `hashbytes-checksum`). Code:
`src/core/types/lob.mbt`, `bind/fn_lob.mbt`, `tds/type_info.mbt`.

## Metadata and wire

- COLMETADATA type TEXT 0x23 / NTEXT 0x63 / IMAGE 0x22 with a 4-byte max
  length (2147483647, 2147483646, 2147483647), the collation for text/ntext,
  then a TableName (bitsql sends 0 parts) before the column name.
- ROW values: TextPointer length (0 = NULL), 16-byte text pointer, 8-byte
  timestamp, 4-byte length, data (CP1252 for text, UTF-16LE for ntext).
- sys.columns: system_type_id 35/99/34, max_length 16; INFORMATION_SCHEMA:
  CHARACTER_MAXIMUM_LENGTH 2147483647 / 1073741823 / 2147483647, octets
  2147483647 / 2147483646 / 2147483647.

## Conversions

text/ntext convert to and from char, varchar, nchar, nvarchar (incl. max) and
each other; image converts to and from binary, varbinary, timestamp and from
char/varchar (not nchar/nvarchar), never to a character type. Everything else
is 529 for CAST and 206 "Operand type clash" for assignment (INSERT of an int
into text). Precedence: ntext > text > image > timestamp, so CASE / IIF /
COALESCE / ISNULL with a LOB branch is that LOB type.

## Operators and clauses

| Use | Result |
| --- | --- |
| `=`, `<>`, `<`, `IN`, NULLIF, join predicates | 402 "The data types text and varchar are incompatible in the equal to operator." |
| `+` | 402 "... in the add operator." |
| LIKE, IS NULL | work (image LIKE: 8116 for argument 2 of like) |
| ORDER BY, GROUP BY | 306 state 2 |
| DISTINCT | 421 |
| UNION / INTERSECT / EXCEPT | 5335 (UNION ALL works) |
| MIN, MAX, COUNT | 8117 (COUNT DISTINCT state 2) |
| DECLARE @v text | 2739 |
| index key / PRIMARY KEY | 1919 (+1750 in CREATE TABLE) |
| COLLATE | text/ntext take it, image is 447 |

## Functions

Accepted: DATALENGTH, SUBSTRING (varchar(n)/nvarchar(n)/varbinary(n) for a
constant length n), CHARINDEX, PATINDEX, CONCAT and CONCAT_WS (as
(n)varchar(max)), ISNULL, COALESCE, IIF, CASE, QUOTENAME, DIFFERENCE (text
only), CONVERT to character types.

Rejected with 8116 ("Argument data type text is invalid for argument 1 of len
function."): LEN, LEFT, RIGHT, UPPER, LOWER, LTRIM, RTRIM, TRIM ("Trim"),
REPLACE, REVERSE, STUFF, REPLICATE, ASCII, UNICODE, SOUNDEX, STRING_ESCAPE,
FORMAT, TRANSLATE, ISJSON, JSON_VALUE, COMPRESS ("Compress"), STRING_AGG,
HASHBYTES (argument 2), CHECKSUM/GREATEST/LEAST (state 4); BINARY_CHECKSUM
of only LOB arguments is 8184. image in CHARINDEX, CONCAT, CONCAT_WS and
QUOTENAME is 206 against (n)varchar.
