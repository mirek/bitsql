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
/// A character string in a date/time format other than the ISO forms the
/// emulator parses (month names, `/` or `.` separated, AM/PM, ...).
pub const EMU_DATETIME_FORMAT_NOT_SUPPORTED : Int = 50102

///|
/// A collation name the emulator does not model.
pub const EMU_COLLATION_NOT_SUPPORTED : Int = 50103

///|
/// A Unicode character without an exact code page 1252 mapping was
/// converted to a non-Unicode type (SQL Server applies a best-fit table the
/// emulator does not have).
pub const EMU_CODE_PAGE_BEST_FIT : Int = 50104

///|
/// A CONVERT style number the emulator does not implement for the types.
pub const EMU_STYLE_NOT_SUPPORTED : Int = 50105

///|
/// Arithmetic on operand types the emulator does not implement (e.g.
/// `datetime + int`).
pub const EMU_OPERATOR_NOT_SUPPORTED : Int = 50106

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
