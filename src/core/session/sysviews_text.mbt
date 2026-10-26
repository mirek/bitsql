///|
/// The catalog view descriptors and seed rows (sysviews_data.mbt,
/// sysviews_system_data.mbt) are text: one MoonBit expression per value or
/// column as scripts/gen-sysviews.mbtx writes it, read back on first use.
/// Array literals of them were start-function code (see @tabletext).
priv enum SvExpr {
  /// `Name` or `Name(args)`; a list `[a, b]` is the call "[]"
  Call(String, Array[SvExpr])
  Num(Int64)
  Str(String)
  Blob(Bytes)
}

///|
priv struct SvReader {
  text : String
  mut pos : Int
}

///|
fn SvReader::peek(self : SvReader) -> Char {
  if self.pos < self.text.length() {
    self.text.unsafe_get(self.pos).unsafe_to_char()
  } else {
    '\u{0}'
  }
}

///|
fn SvReader::skip_spaces(self : SvReader) -> Unit {
  while self.peek() == ' ' {
    self.pos += 1
  }
}

///|
fn SvReader::expect(self : SvReader, c : Char) -> Unit {
  self.skip_spaces()
  guard self.peek() == c else {
    abort("sysviews text: expected \{c} at \{self.pos} in \{self.text}")
  }
  self.pos += 1
}

///|
fn SvReader::list(self : SvReader, close : Char) -> Array[SvExpr] {
  let items = []
  self.skip_spaces()
  if self.peek() == close {
    self.pos += 1
    return items
  }
  while true {
    items.push(self.expr())
    self.skip_spaces()
    if self.peek() == ',' {
      self.pos += 1
    } else {
      self.expect(close)
      break
    }
  }
  items
}

///|
fn SvReader::quoted(self : SvReader) -> String {
  self.expect('"')
  let out = StringBuilder()
  while self.peek() != '"' {
    let c = self.peek()
    if c == '\\' {
      self.pos += 1
    }
    out.write_char(self.peek())
    self.pos += 1
  }
  self.pos += 1
  out.to_string()
}

///|
fn SvReader::expr(self : SvReader) -> SvExpr {
  self.skip_spaces()
  let c = self.peek()
  if c == '"' {
    return Str(self.quoted())
  }
  if c == '[' {
    self.pos += 1
    return Call("[]", self.list(']'))
  }
  if c == 'b' &&
    self.text.length() > self.pos + 1 &&
    self.text.unsafe_get(self.pos + 1) == '"' {
    self.pos += 1
    let hex = self.quoted()
    // \xNN per byte; the reader dropped each backslash
    return Blob(
      Bytes::makei(hex.length() / 3, i => {
        @tabletext.int(
          "0x" +
          hex.view(start_offset=3 * i + 1, end_offset=3 * i + 3).to_owned(),
        ).to_byte()
      }),
    )
  }
  if c == '-' || (c >= '0' && c <= '9') {
    let start = self.pos
    self.pos += 1
    while self.peek() >= '0' && self.peek() <= '9' {
      self.pos += 1
    }
    let n = @tabletext.int64(
      self.text.view(start_offset=start, end_offset=self.pos),
    )
    if self.peek() == 'L' {
      self.pos += 1
    }
    return Num(n)
  }
  let start = self.pos
  while self.peek() is ('a'..='z' | 'A'..='Z' | '0'..='9' | '_' | '@' | '.') {
    self.pos += 1
  }
  guard self.pos > start else {
    abort("sysviews text: unexpected \{c} at \{self.pos} in \{self.text}")
  }
  let name = self.text.view(start_offset=start, end_offset=self.pos).to_owned()
  let args = if self.peek() == '(' {
    self.pos += 1
    self.list(')')
  } else {
    []
  }
  // `@types.parse_guid("…").unwrap()`
  if self.text.view(start_offset=self.pos).has_prefix(".unwrap()") {
    self.pos += 9
  }
  Call(name, args)
}

///|
fn sv_parse(line : StringView) -> SvExpr {
  let r = { text: line.to_owned(), pos: 0, }
  let e = r.expr()
  r.skip_spaces()
  guard r.pos == r.text.length() else {
    abort("sysviews text: trailing input in \{r.text}")
  }
  e
}

///|
fn sv_int(e : SvExpr) -> Int {
  guard e is Num(n) else { abort("sysviews text: expected a number") }
  n.to_int()
}

///|
fn sv_collation(e : SvExpr) -> @types.Collation {
  match e {
    Call("coll_default", []) => coll_default
    Call("coll_ks_ws", []) => coll_ks_ws
    Call("@types.json_collation", []) => @types.json_collation
    _ => abort("sysviews text: unknown collation")
  }
}

///|
fn sv_len(e : SvExpr) -> Int? {
  match e {
    Call("None", []) => None
    Call("Some", [n]) => Some(sv_int(n))
    _ => abort("sysviews text: expected an optional length")
  }
}

///|
fn sv_type(e : SvExpr) -> @types.SqlType {
  match e {
    Call("Bit", []) => Bit
    Call("TinyInt", []) => TinyInt
    Call("SmallInt", []) => SmallInt
    Call("Int", []) => Int
    Call("BigInt", []) => BigInt
    Call("Float", []) => Float
    Call("Real", []) => Real
    Call("DateTime", []) => DateTime
    Call("SmallDateTime", []) => SmallDateTime
    Call("UniqueIdentifier", []) => UniqueIdentifier
    Call("Variant", []) => Variant
    Call("Json", []) => Json
    Call("DateTimeOffset", [s]) => DateTimeOffset(sv_int(s))
    Call("DateTime2", [s]) => DateTime2(sv_int(s))
    Call("Binary", [n]) => Binary(sv_int(n))
    Call("VarBinary", [n]) => VarBinary(sv_len(n))
    Call("Numeric", [p, s]) => Numeric(sv_int(p), sv_int(s))
    Call("Char", [n, c]) => Char(sv_int(n), sv_collation(c))
    Call("NChar", [n, c]) => NChar(sv_int(n), sv_collation(c))
    Call("VarChar", [n, c]) => VarChar(sv_len(n), sv_collation(c))
    Call("NVarChar", [n, c]) => NVarChar(sv_len(n), sv_collation(c))
    _ => abort("sysviews text: unknown type")
  }
}

///|
fn sv_value(e : SvExpr) -> @types.Value {
  match e {
    Call("Null", []) => Null
    Call("Bit", [Call("true", [])]) => Bit(true)
    Call("Bit", [Call("false", [])]) => Bit(false)
    Call("TinyInt", [n]) => TinyInt(sv_int(n))
    Call("SmallInt", [n]) => SmallInt(sv_int(n))
    Call("Int", [n]) => Int(sv_int(n))
    Call("BigInt", [Num(n)]) => BigInt(n)
    Call("DateTime", [d, t]) => DateTime(sv_int(d), sv_int(t))
    Call("String", [Str(s)]) => String(s)
    Call("Binary", [Blob(b)]) => Binary(b)
    Call("Guid", [Call("@types.parse_guid", [Str(s)])]) =>
      Guid(@types.parse_guid(s).unwrap())
    Call("Variant", [v, t]) => Variant(sv_value(v), sv_type(t))
    _ => abort("sysviews text: unknown value")
  }
}

///|
/// Rows of `[value, …]` lines.
fn sv_rows(text : String) -> Array[Array[@types.Value]] {
  text
  .split("\n")
  .map(line => {
    guard sv_parse(line) is Call("[]", items) else {
      abort("sysviews text: expected a row")
    }
    items.map(sv_value)
  })
  .collect()
}

///|
/// `schema.name` header lines, each followed by its
/// `vc("name", type, nullable, computed)` lines.
fn sv_view_defs(text : String) -> Array[ViewDef] {
  let defs : Array[ViewDef] = []
  for line in text.split("\n") {
    if line.has_prefix("vc(") {
      guard sv_parse(line)
        is Call("vc", [Str(name), ty, Call(nullable, []), Call(computed, [])]) else {
        abort("sysviews text: bad column \{line}")
      }
      defs[defs.length() - 1].columns.push(
        vc(name, sv_type(ty), nullable == "true", computed == "true"),
      )
    } else {
      guard line.split_once(".") is Some((schema, name)) else {
        abort("sysviews text: bad view \{line}")
      }
      defs.push({
        schema: schema.to_owned(),
        name: name.to_owned(),
        columns: [],
      })
    }
  }
  defs
}

///|
priv struct SysviewTables {
  view_defs : Array[ViewDef]
  seed_system_objects : Array[Array[@types.Value]]
  seed_types : Array[Array[@types.Value]]
  seed_databases : Array[Array[@types.Value]]
  seed_scoped_configurations : Array[Array[@types.Value]]
  seed_configurations : Array[Array[@types.Value]]
  seed_server_principals : Array[Array[@types.Value]]
}

///|
let sysview_tables : Ref[SysviewTables?] = Ref(None)

///|
fn sysviews() -> SysviewTables {
  if sysview_tables.val is Some(t) {
    return t
  }
  let t = {
    view_defs: sv_view_defs(view_def_text),
    seed_system_objects: sv_rows(seed_system_objects_text),
    seed_types: sv_rows(seed_types_text),
    seed_databases: sv_rows(seed_databases_text),
    seed_scoped_configurations: sv_rows(seed_scoped_configurations_text),
    seed_configurations: sv_rows(seed_configurations_text),
    seed_server_principals: sv_rows(seed_server_principals_text),
  }
  sysview_tables.val = Some(t)
  t
}

///|
fn view_defs() -> Array[ViewDef] {
  sysviews().view_defs
}

///|
fn seed_system_objects() -> Array[Array[@types.Value]] {
  sysviews().seed_system_objects
}

///|
fn seed_types() -> Array[Array[@types.Value]] {
  sysviews().seed_types
}

///|
fn seed_databases() -> Array[Array[@types.Value]] {
  sysviews().seed_databases
}

///|
fn seed_scoped_configurations() -> Array[Array[@types.Value]] {
  sysviews().seed_scoped_configurations
}

///|
fn seed_configurations() -> Array[Array[@types.Value]] {
  sysviews().seed_configurations
}

///|
fn seed_server_principals() -> Array[Array[@types.Value]] {
  sysviews().seed_server_principals
}
