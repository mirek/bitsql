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
  let bytes = @utf8.encode(@types.replace_lone_surrogates(source))
  ctx.rt.charge(bytes.length().to_int64())
  // Every nonempty prefix of a valid UTF-8 scalar decodes to one character,
  // including an incomplete final prefix. Precompute end positions once.
  let prefix_chars = Array::make(bytes.length() + 1, 0)
  let mut cursor = 0
  let mut size = 0
  while cursor < bytes.length() {
    let next = @regex.next_boundary(bytes, cursor)
    size += 1
    for i in (cursor + 1)..<(next + 1) {
      prefix_chars[i] = size
    }
    cursor = next
  }
  let mut position_byte = 0
  let mut position_chars = 0
  let mut at = 0
  let mut copied = 0
  let mut ordinal = 0L
  while program.find(bytes, at, n => ctx.rt.charge(n)) is Some(m) {
    let (a, b) = m.groups[0].unwrap()
    if kind is RegexMatches {
      ordinal += 1L
      position_chars += regex_text(bytes, position_byte, a).char_length()
      position_byte = a
      let start = if a == bytes.length() {
        position_chars
      } else {
        position_chars + 1
      }
      let end = @cmp.maximum(start, prefix_chars[b])
      let raw_strings : Array[(String, Bytes)] = []
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
            let s = if x == bytes.length() {
              start.max(size)
            } else {
              start + regex_text(bytes, a, x).char_length()
            }
            let mut len = 0
            for i in x..<y {
              if (bytes[i].to_int() & 0xC0) != 0x80 {
                len += 1
              }
            }
            if x != y {
              len = len.max(1)
            }
            raw_strings.push(
              (
                "$[" + (j - first).to_string() + "].value",
                bytes[x:y].to_owned(),
              ),
            )
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
        NativeJson(
          @types.JsonData::parse_raw_strings(parts.to_string(), raw_strings),
        ),
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
