///|
/// Table regex positions count Unicode scalars, unlike scalar INSTR's UTF-16
/// positions. Captured empty matches clamp their one-based start to input size.
fn regex_table(
  ctx : Ctx,
  kind : @ir.TableFn,
  args : Array[@ir.Expr],
  emit : (Row) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  let values = args.map(a => eval(ctx, a))
  if values.any(v => v is Null) {
    return
  }
  guard values[0] is String(source) &&
    values[1] is String(pattern) &&
    values[2] is String(flags) else {
    raise @types.not_supported("non-string regular expression arguments")
  }
  let program = @regex.compile(pattern, flags)
  let bytes = @utf8.encode(source)
  ctx.rt.charge(bytes.length().to_int64())
  let positions : Map[Int, Int] = Map([])
  let mut cursor = 0
  let mut size = 0
  while cursor < bytes.length() {
    positions[cursor] = size
    cursor = @regex.next_boundary(bytes, cursor)
    size += 1
  }
  positions[bytes.length()] = size
  let position = (offset : Int) => {
    match positions.get(offset) {
      Some(n) => n
      None =>
        raise @types.not_supported(
          "regular expression captures that split UTF-8 characters",
        )
    }
  }
  let mut at = 0
  let mut copied = 0
  let mut ordinal = 0L
  while program.find(bytes, at, n => ctx.rt.charge(n)) is Some(m) {
    let (a, b) = m.groups[0].unwrap()
    if kind is RegexMatches {
      ordinal += 1L
      let start = @cmp.minimum(position(a) + 1, size)
      let end = @cmp.maximum(start, position(b))
      let parts = StringBuilder()
      parts.write_char('[')
      let first = if m.groups.length() > 1 { 1 } else { 0 }
      for j in first..<m.groups.length() {
        if j > first {
          parts.write_char(',')
        }
        match m.groups[j] {
          None =>
            parts.write_string(
              "{\"value\":null,\"start\":null,\"length\":null}",
            )
          Some((x, y)) => {
            let text = @json.quote(regex_text(bytes, x, y))
            let s = @cmp.minimum(position(x) + 1, size)
            let len = position(y) - position(x)
            parts.write_string(
              "{\"value\":\{text},\"start\":\{s},\"length\":\{len}}",
            )
          }
        }
      }
      parts.write_char(']')
      emit([
        BigInt(ordinal),
        Int(start),
        Int(end),
        String(regex_text(bytes, a, b)),
        String(parts.to_string()),
      ])
    } else if a != b || (a > copied && a < bytes.length()) {
      ordinal += 1L
      emit([String(regex_text(bytes, copied, a)), BigInt(ordinal)])
      copied = b
    }
    at = if a == b { @regex.next_boundary(bytes, b) } else { b }
  }
  if kind is RegexSplit {
    emit([
      String(regex_text(bytes, copied, bytes.length())),
      BigInt(ordinal + 1L),
    ])
  }
}
