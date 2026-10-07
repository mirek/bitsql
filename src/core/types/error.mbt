///|
/// SQL execution failure or internal suspension, shared across the core.
/// Only the SqlError constructor is a client-visible diagnostic. Suspend
/// propagates to the session request boundary and has no SQL error fields.
pub(all) suberror SqlError {
  SqlError(number~ : Int, severity~ : Int, state~ : Int, message~ : String)
  /// Internal execution control, never a SQL diagnostic. The session must
  /// unwind and restart the request when an expression or scan waits.
  Suspend
} derive(Debug, Eq)

///|
/// Message number.
pub fn SqlError::number(self : SqlError) -> Int {
  match self {
    SqlError(number~, ..) => number
    Suspend => abort("suspension has no SQL error number")
  }
}

///|
/// Severity (TDS "class").
pub fn SqlError::severity(self : SqlError) -> Int {
  match self {
    SqlError(severity~, ..) => severity
    Suspend => abort("suspension has no SQL severity")
  }
}

///|
/// Error state.
pub fn SqlError::state(self : SqlError) -> Int {
  match self {
    SqlError(state~, ..) => state
    Suspend => abort("suspension has no SQL error state")
  }
}

///|
/// Formatted message text.
pub fn SqlError::message(self : SqlError) -> String {
  match self {
    SqlError(message~, ..) => message
    Suspend => abort("suspension has no SQL error message")
  }
}

///|
/// `Msg 245, Level 16, State 1: Conversion failed ...` (SSMS-like).
pub impl Show for SqlError with fn output(self, logger) {
  if self is Suspend {
    logger.write_string("execution suspended")
    return
  }
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
  if self is Suspend {
    return false
  }
  match self.number() {
    220
    | 232
    | 235
    | 241
    | 242
    | 244
    | 245
    | 248
    // style errors (captured: TRY_CONVERT(varchar, datetime, 99) and
    // TRY_CONVERT(date, '…', 128) are NULL)
    | 281
    | 9809
    | 293
    | 295
    | 294
    | 8114
    | 8115
    | 8169
    | 8170
    | 9807 => true
    // json type: malformed text, nesting, target too small, code page
    // (captured json4: TRY_CAST is NULL; 1007 still raises)
    13609 | 13645 | 13639 | 13640 => true
    // XML parse errors (captured: TRY_CAST(N'<a>' AS xml) is NULL)
    n if n >= 9400 && n < 9500 => true
    _ => false
  }
}
