// Emulator error allocation table (docs/design/fidelity-traps.md).
//
// Range 50100–50199, severity 16, message prefix `Emulator: `. The numbers
// sit in the user-error range (clients treat them as ordinary errors) and
// above 50000 so they never collide with a real system message. Allocate a
// new number by adding a constant here *and* a row to `emulator_error_table`;
// never reuse or renumber an allocated one.

///|
/// Generic "feature X is not supported".
pub const EMU_NOT_SUPPORTED : Int = 50100

///|
/// A CAST/CONVERT between two types the emulator does not implement yet.
pub const EMU_CONVERSION_NOT_SUPPORTED : Int = 50101

///|
/// Retired (2026-10-03): character strings in every us_english / mdy
/// format now parse (date_parse.mbt). The number stays reserved.
pub const EMU_DATETIME_FORMAT_NOT_SUPPORTED : Int = 50102

///|
/// A collation name the emulator does not model.
pub const EMU_COLLATION_NOT_SUPPORTED : Int = 50103

///|
/// Retired (2026-10-03): Unicode → code page 1252 now applies SQL Server's
/// captured best-fit table (cp1252_best_fit.mbt). The number stays reserved.
pub const EMU_CODE_PAGE_BEST_FIT : Int = 50104

///|
/// A CONVERT style number the emulator does not implement for the types.
pub const EMU_STYLE_NOT_SUPPORTED : Int = 50105

///|
/// Arithmetic on operand types the emulator does not implement (e.g.
/// `datetime + int`).
pub const EMU_OPERATOR_NOT_SUPPORTED : Int = 50106

///|
/// COMMIT found a change by another transaction to the same rows or objects
/// that no lock prevented (e.g. DDL racing DML); see decisions.md.
pub const EMU_CONCURRENT_CONFLICT : Int = 50107

///|
/// A request exceeded the work budget (runaway loop or join): execution is
/// single-threaded, so one endless request would stall every session.
pub const EMU_WORK_BUDGET : Int = 50108

///|
/// TABLESAMPLE with a size other than 0 or 100 PERCENT: SQL Server samples
/// whole pages, nondeterministically (captured: analytic/tablesample).
pub const EMU_TABLESAMPLE : Int = 50150

///|
/// APPROX_COUNT_DISTINCT over more distinct values than the range where
/// SQL Server's HyperLogLog estimate was captured to be exact (30).
pub const EMU_APPROX_COUNT_DISTINCT : Int = 50151

///|
/// DATE_BUCKET with a width SQL Server computes with 32-bit month
/// arithmetic overflow (year/quarter widths beyond int32 months).
pub const EMU_DATE_BUCKET_WIDTH : Int = 50170

///|
/// PARSE / TRY_PARSE with a culture other than en-US or the invariant one.
pub const EMU_PARSE_CULTURE : Int = 50171

///|
/// PARSE / TRY_PARSE of a date/time string outside the modelled .NET
/// formats (time-only text, zone designators, uncommon shapes).
pub const EMU_PARSE_FORMAT : Int = 50172

///|
/// FORMAT with a real culture bitsql has no .NET culture data for, or a
/// date in a non-Gregorian culture calendar (Hijri).
pub const EMU_FORMAT_CULTURE : Int = 50173

///|
/// An XML or XQuery feature the emulator does not implement (FOR XML
/// EXPLICIT, XQuery beyond the path subset, DTDs, typed xml).
pub const EMU_XML_NOT_SUPPORTED : Int = 50109

///|
/// An internal invariant was violated (e.g. the binder handed the evaluator
/// operands of incompatible families). Always a bitsql bug.
pub const EMU_INTERNAL : Int = 50199

///|
/// The allocation table: number and what it is for. Kept as data so tests
/// can check the range and uniqueness.
pub let emulator_error_table : Array[(Int, String)] = [
  (EMU_NOT_SUPPORTED, "feature not supported"),
  (EMU_CONVERSION_NOT_SUPPORTED, "conversion not supported"),
  (EMU_DATETIME_FORMAT_NOT_SUPPORTED, "date/time string format not supported"),
  (EMU_COLLATION_NOT_SUPPORTED, "collation not supported"),
  (EMU_CODE_PAGE_BEST_FIT, "no exact code page mapping (best-fit)"),
  (EMU_STYLE_NOT_SUPPORTED, "CONVERT style not supported"),
  (EMU_OPERATOR_NOT_SUPPORTED, "operator on these types not supported"),
  (EMU_CONCURRENT_CONFLICT, "unprotected concurrent change at commit"),
  (EMU_WORK_BUDGET, "request work budget exceeded"),
  (EMU_TABLESAMPLE, "TABLESAMPLE page sampling"),
  (EMU_APPROX_COUNT_DISTINCT, "APPROX_COUNT_DISTINCT estimate"),
  (EMU_DATE_BUCKET_WIDTH, "DATE_BUCKET width overflowing int32 months"),
  (EMU_PARSE_CULTURE, "PARSE culture not supported"),
  (EMU_PARSE_FORMAT, "PARSE date/time format not supported"),
  (EMU_FORMAT_CULTURE, "FORMAT culture not supported"),
  (EMU_XML_NOT_SUPPORTED, "XML/XQuery feature not supported"),
  (EMU_INTERNAL, "internal invariant violated"),
]

///|
/// Build an emulator error: severity 16, state 1, message
/// `Emulator: <detail>`.
pub fn emulator_error(number : Int, detail : String) -> SqlError {
  SqlError(number~, severity=16, state=1, message="Emulator: \{detail}")
}

///|
/// `Emulator: <feature> is not supported.` (number 50100 unless given).
pub fn not_supported(
  feature : String,
  number? : Int = EMU_NOT_SUPPORTED,
) -> SqlError {
  emulator_error(number, "\{feature} is not supported.")
}
