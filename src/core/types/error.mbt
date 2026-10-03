///|
/// A SQL Server error as the client sees it: message number, severity
/// (class), state and the fully formatted message text. Shared across the
/// whole core: every package that raises user-visible errors raises this.
pub(all) suberror SqlError {
  SqlError(number~ : Int, severity~ : Int, state~ : Int, message~ : String)
} derive(Debug, Eq)

///|
/// Message number.
pub fn SqlError::number(self : SqlError) -> Int {
  match self {
    SqlError(number~, ..) => number
  }
}

///|
/// Severity (TDS "class").
pub fn SqlError::severity(self : SqlError) -> Int {
  match self {
    SqlError(severity~, ..) => severity
  }
}

///|
/// Error state.
pub fn SqlError::state(self : SqlError) -> Int {
  match self {
    SqlError(state~, ..) => state
  }
}

///|
/// Formatted message text.
pub fn SqlError::message(self : SqlError) -> String {
  match self {
    SqlError(message~, ..) => message
  }
}

///|
/// `Msg 245, Level 16, State 1: Conversion failed ...` (SSMS-like).
pub impl Show for SqlError with fn output(self, logger) {
  logger.write_string(
    "Msg \{self.number()}, Level \{self.severity()}, State \{self.state()}: \{self.message()}",
  )
}

///|
/// Build an error; severity defaults to 16 and state to 1.
pub fn sql_error(
  number : Int,
  message : String,
  state? : Int = 1,
  severity? : Int = 16,
) -> SqlError {
  SqlError(number~, severity~, state~, message~)
}

///|
/// True for the errors that `TRY_CAST` / `TRY_CONVERT` turn into NULL:
/// value-dependent conversion failures and overflows. Disallowed
/// conversions (529), source truncation (8152, captured: TRY_CAST still
/// raises it) and emulator errors keep raising.
pub fn SqlError::is_try_convertible(self : SqlError) -> Bool {
  match self.number() {
    220
    | 232
    | 235
    | 241
    | 242
    | 244
    | 245
    | 248
    | 293
    | 295
    | 294
    | 8114
    | 8115
    | 8169
    | 8170
    | 9807 => true
    _ => false
  }
}
