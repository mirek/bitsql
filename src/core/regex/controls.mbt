///|
/// Captured control errors have function-specific states, including INSTR's
/// GROUP text saying minimum 1 although zero is accepted.
pub fn validate_control(
  name : String,
  label : String,
  n : Int64,
) -> Unit raise @types.SqlError {
  let (state, minimum, valid) = match (name, label) {
    ("REGEXP_COUNT", "START") => (0, 1, n >= 1L)
    ("REGEXP_REPLACE", "START") => (1, 1, n >= 1L)
    ("REGEXP_REPLACE", "OCCURRENCE") => (2, 0, n >= 0L)
    ("REGEXP_INSTR", "START") => (3, 1, n >= 1L)
    ("REGEXP_INSTR", "OCCURRENCE") => (4, 1, n >= 1L)
    ("REGEXP_INSTR", "GROUP") => (5, 1, n >= 0L)
    ("REGEXP_INSTR", "RETURN_OPTION") => (6, 0, n == 0L || n == 1L)
    ("REGEXP_SUBSTR", "START") => (7, 1, n >= 1L)
    ("REGEXP_SUBSTR", "OCCURRENCE") => (8, 1, n >= 1L)
    ("REGEXP_SUBSTR", "GROUP") => (9, 0, n >= 0L)
    _ => return
  }
  if !valid {
    raise @types.sql_error(
      19301,
      "'\{label}' value should be greater than or equal to \{minimum} but '\{n}' is provided in '\{name}' function.",
      state~,
    )
  }
}
