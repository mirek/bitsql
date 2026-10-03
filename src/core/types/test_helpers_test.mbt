// Shared helpers for the black-box tests.

///|
let coll : @types.Collation = @types.default_collation

///|
fn vc(n? : Int) -> @types.SqlType {
  @types.VarChar(n, coll)
}

///|
fn nvc(n? : Int) -> @types.SqlType {
  @types.NVarChar(n, coll)
}

///|
fn s(x : String) -> @types.Value {
  @types.String(x)
}

///|
/// "ok <value>" or "<number>/<state> <message>".
fn outcome(f : () -> @types.Value raise @types.SqlError) -> String {
  try f() catch {
    e => "\{e.number()}/\{e.state()} \{e.message()}"
  } noraise {
    v => "ok \{repr(v)}"
  }
}

///|
/// Short value text for snapshots.
fn repr(v : @types.Value) -> String {
  match v {
    Null => "NULL"
    String(x) => "'" + x + "'"
    Decimal(d) => d.to_string()
    _ => @types.render(v, ty_of(v), None) catch { _ => "?" }
  }
}

///|
fn ty_of(v : @types.Value) -> @types.SqlType {
  match v {
    Bit(_) => Bit
    TinyInt(_) => TinyInt
    SmallInt(_) => SmallInt
    Int(_) => Int
    BigInt(_) => BigInt
    Money(_) => Money
    Float(_) => Float
    Binary(_) => VarBinary(None)
    Date(_) => Date
    Time(_) => Time(7)
    DateTime2(_) => DateTime2(7)
    DateTimeOffset(_, _) => DateTimeOffset(7)
    DateTime(_, _) => DateTime
    SmallDateTime(_, _) => SmallDateTime
    Guid(_) => UniqueIdentifier
    _ => vc()
  }
}

///|
/// cast to a string type and return the text (or the error outcome).
fn text_of(
  v : @types.Value,
  from : @types.SqlType,
  style? : Int,
  to? : @types.SqlType = vc(),
) -> String {
  let r = outcome(() => @types.cast(v, from, to, style?))
  if r.has_prefix("ok '") {
    r.unsafe_substring(start=4, end=r.length() - 1)
  } else {
    r
  }
}

///|
fn dec(text : String) -> @types.Value {
  @types.Decimal(@types.Decimal::parse(text).unwrap())
}
