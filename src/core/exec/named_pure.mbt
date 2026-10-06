// Named built-ins that only the executor implements (`call_more`): their
// calls skip the session's catalog/property/security function chain, which
// otherwise runs first on every evaluation (string matches, closures and a
// database lookup per row; `NCHAR(...)` in an ORDER BY cost ~320 ns/row).
// session/named_pure_test.mbt checks that the chain answers none of them,
// so skipping it cannot change a result.

///|
let pure_named_list : Array[String] = [
  "ABS", "ACOS", "ASCII", "ASIN", "AT TIME ZONE", "ATAN", "ATN2", "BINARY_CHECKSUM",
  "CEILING", "CHAR", "CHARINDEX", "CHECKSUM", "COMPRESS", "CONCAT", "CONCAT_WS",
  "COS", "COT", "DATALENGTH", "DATEADD", "DATEDIFF", "DATEDIFF_BIG", "DATEFROMPARTS",
  "DATENAME", "DATEPART", "DATETIME2FROMPARTS", "DATETIMEFROMPARTS", "DATETIMEOFFSETFROMPARTS",
  "DATETRUNC", "DATE_BUCKET", "DECOMPRESS", "DEGREES", "DIFFERENCE", "DIFFERENCE_100",
  "EOMONTH", "EXP", "FLOOR", "FORMAT", "GREATEST", "HASHBYTES", "ISDATE", "ISJSON",
  "ISNUMERIC", "JSON_ARRAY", "JSON_CONTAINS", "JSON_MODIFY", "JSON_OBJECT", "JSON_PATH_EXISTS",
  "LEAST", "LEFT", "LEN", "LOG", "LOG10", "LOWER", "LTRIM", "NCHAR", "PARSE", "PATINDEX",
  "PI", "POWER", "QUOTENAME", "RADIANS", "RAND", "REPLACE", "REPLICATE", "REVERSE",
  "RIGHT", "ROUND", "ROWCOUNT_BIG", "RTRIM", "SERVERPROPERTY", "SIGN", "SIN", "SMALLDATETIMEFROMPARTS",
  "SOUNDEX", "SOUNDEX_100", "SPACE", "SQL_VARIANT_PROPERTY", "SQRT", "SQUARE", "STR",
  "STRING_ESCAPE", "STUFF", "SUBSTRING", "SWITCHOFFSET", "TAN", "TIMEFROMPARTS",
  "TODATETIMEOFFSET", "TRANSLATE", "TRIM", "TRY_CONVERT_STYLE", "UNICODE", "UPPER",
]

///|
let pure_named : Set[String] = Set::from_array(pure_named_list)

///|
/// The names of `pure_named`, for the session's guard test.
pub fn pure_named_functions() -> Array[String] {
  pure_named_list.copy()
}
