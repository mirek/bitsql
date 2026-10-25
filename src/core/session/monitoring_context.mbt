///|
priv struct QueryStoreContext {
  id : Int64
  options : Int
  language : Int
  format : Int
  datefirst : Int
}

///|
/// Oracle context-settings: NOCOUNT/XACT_ABORT do not change plan identity.
fn Session::query_store_context(self : Session) -> (Int, Int, Int, Int) {
  let bits = self.query_store_option_bits()
  let format = match self.rt.dates.format {
    Mdy => 1
    Dmy => 2
    Ymd => 3
    Ydm => 4
    Myd => 5
    Dym => 6
  }
  (bits, self.rt.dates.language, format, self.rt.datefirst)
}

///|
/// The set_options bits of `query_store_context` (memoized per
/// `flags_version`).
fn Session::query_store_option_bits(self : Session) -> Int {
  if self.option_bits_memo is Some((version, bits)) &&
    version == self.flags_version {
    return bits
  }
  let mut bits = 130 // ANSI_NULL_DFLT_ON plus the captured default status bit.
  for
    (name, mask, default_) in [
      ("ANSI_PADDING", 1, true),
      ("CONCAT_NULL_YIELDS_NULL", 8, true),
      ("ANSI_WARNINGS", 16, true),
      ("ANSI_NULLS", 32, true),
      ("QUOTED_IDENTIFIER", 64, true),
      ("ARITHABORT", 4096, true),
      ("NUMERIC_ROUNDABORT", 8192, false),
    ] {
    if self.session_flags.get(name).unwrap_or(default_) {
      bits = bits | mask
    }
  }
  self.option_bits_memo = Some((self.flags_version, bits))
  bits
}

///|
fn QueryStoreContext::row(self : QueryStoreContext) -> VRow {
  vrow([
    ("context_settings_id", BigInt(self.id)),
    (
      "set_options",
      Binary(Bytes::makei(4, i => (self.options >> (8 * (3 - i))).to_byte())),
    ),
    ("language_id", SmallInt(self.language)),
    ("date_format", SmallInt(self.format)),
    ("date_first", TinyInt(self.datefirst)),
    ("status", Binary(b"\x04\x00")),
    ("required_cursor_options", Int(0)),
    ("acceptable_cursor_options", Int(0)),
    ("merge_action_type", SmallInt(0)),
    ("default_schema_id", Int(-2)),
    ("is_replication_specific", Bit(false)),
    ("is_contained", Binary(b"\x00")),
  ])
}
