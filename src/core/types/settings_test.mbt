///|
/// Text of a string → date/time cast under a date order and language.
fn cast_date_text(
  s : String,
  to : @types.SqlType,
  format : @types.DateFormat,
  language? : Int = 0,
) -> String {
  let dates : @types.DateSettings = { format, language, }
  let v = @types.try_cast(
    String(s),
    VarChar(Some(40), @types.default_collation),
    to,
    dates~,
  ) catch {
    e => return "error \{e.number()}"
  }
  if v is Null {
    return "NULL"
  }
  let text = @types.try_cast(
    v,
    to,
    VarChar(Some(40), @types.default_collation),
    style=121,
  ) catch {
    _ => return "?"
  }
  match text {
    String(t) => t
    _ => "?"
  }
}

///|
test "DATEFORMAT orders (captured: settings/dateformat)" {
  let rows = [
    ("1/2/2024", @types.DateFormat::Dmy),
    ("2024-01-02", Dmy),
    ("1/2/24", Ymd),
    ("1/2/2024", Ymd),
    ("2024/1/2", Ydm),
    ("1/2/3", Myd),
    ("1/2024/2", Dym),
  ]
  let out = rows.map(r => {
    cast_date_text(r.0, Date, r.1) + " " + cast_date_text(r.0, DateTime, r.1)
  })
  debug_inspect(
    out,
    content=(
      #|[
      #|  "2024-02-01 2024-02-01 00:00:00.000",
      #|  "2024-01-02 2024-02-01 00:00:00.000",
      #|  "2001-02-24 2001-02-24 00:00:00.000",
      #|  "2024-01-02 2024-01-02 00:00:00.000",
      #|  "2024-01-02 2024-02-01 00:00:00.000",
      #|  "2002-01-03 2002-01-03 00:00:00.000",
      #|  "2024-02-01 2024-02-01 00:00:00.000",
      #|]
    ),
  )
}

///|
test "month names follow the language (captured: settings/language)" {
  let german = @types.find_language("German").map(l => l.langid).unwrap_or(-1)
  debug_inspect(
    [
      cast_date_text("4 März 2024", Date, Dmy, language=german),
      cast_date_text("4 MÄRZ 2024", Date, Dmy, language=german),
      cast_date_text("4 March 2024", Date, Dmy, language=german),
      cast_date_text("4 March 2024", Date, Mdy),
    ],
    content=(
      #|["2024-03-04", "2024-03-04", "NULL", "2024-03-04"]
    ),
  )
}

///|
test "UTF-8 byte lengths" {
  debug_inspect(
    (
      @types.utf8_length("aé€😀"),
      @types.utf8_prefix("ééééé", 5),
      @types.utf8_bytes("é"),
    ),
    content=(
      #|(10, "éé", <Bytes: [0xc3, 0xa9]>)
    ),
  )
}
