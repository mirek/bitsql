///|
fn regex_text(bytes : Bytes, start : Int, end : Int) -> String {
  @utf8.decode_lossy(bytes[start:end])
}

///|
fn regex_replacement(
  replacement : Bytes,
  bytes : Bytes,
  m : @regex.Match,
  out : Buffer,
) -> Unit {
  let mut i = 0
  while i < replacement.length() {
    let c = replacement[i].to_int()
    if c == 92 && i + 1 < replacement.length() {
      let next = replacement[i + 1].to_int()
      if next >= 49 && next <= 57 {
        let group = next - 48
        if group < m.groups.length() && m.groups[group] is Some((a, b)) {
          out.write_bytes(bytes[a:b])
        }
        i += 2
        continue
      }
      if next == 92 {
        out.write_byte(replacement[i])
        i += 2
        continue
      }
    }
    out.write_byte(replacement[i])
    i += 1
  }
}

///|
fn call_regex(
  ctx : Ctx,
  name : String,
  v : Array[@types.Value],
  e : @ir.Expr,
) -> @types.Value? raise @types.SqlError {
  if !(name
    is ("REGEXP_COUNT"
    | "REGEXP_SUBSTR"
    | "REGEXP_INSTR"
    | "REGEXP_REPLACE"
    | "REGEXP_LIKE")) {
    return None
  }
  for j in 0..<v.length() {
    if v[j] is Null && !(name == "REGEXP_INSTR" && j == 6) {
      return Some(Null)
    }
  }
  guard v[0] is String(source) &&
    v[1] is String(pattern) &&
    v[4] is String(flags) &&
    v[7] is String(replacement) else {
    raise @types.not_supported("non-string regular expression arguments")
  }
  let start = v[2].as_int64().unwrap_or(1L).to_int()
  let occurrence = v[3].as_int64().unwrap_or(1L).to_int()
  let group = v[5].as_int64().unwrap_or(0L).to_int()
  let return_option = v[6].as_int64().unwrap_or(0L).to_int()
  @regex.validate_control(name, "START", start.to_int64())
  @regex.validate_control(name, "OCCURRENCE", occurrence.to_int64())
  @regex.validate_control(name, "GROUP", group.to_int64())
  @regex.validate_control(name, "RETURN_OPTION", return_option.to_int64())
  let program = @regex.compile(pattern, flags)
  let bytes = @utf8.encode(@types.replace_lone_surrogates(source))
  let replacement_bytes = @utf8.encode(
    @types.replace_lone_surrogates(replacement),
  )
  let mut at = 0
  let mut char_pos = 1
  while at <= bytes.length() && char_pos < start {
    at = @regex.next_boundary(bytes, at)
    char_pos += 1
  }
  let mut count = 0
  let mut copied = 0
  let output = Buffer()
  let mut changed = false
  while program.find(bytes, at, n => ctx.rt.charge(n)) is Some(m) {
    let (a, b) = m.groups[0].unwrap()
    count += 1
    if name == "REGEXP_LIKE" {
      return Some(Bit(true))
    }
    if name == "REGEXP_REPLACE" {
      if occurrence == 0 || occurrence == count {
        changed = true
        output.write_bytes(bytes[copied:a])
        let before = output.length()
        regex_replacement(replacement_bytes, bytes, m, output)
        ctx.rt.charge((output.length() - before).to_int64())
        if output.length() > 8_000_000 {
          raise @types.emulator_error(
            @types.EMU_WORK_BUDGET,
            "regular expression replacement exceeded the output budget",
          )
        }
        copied = b
        if occurrence != 0 {
          break
        }
      }
    } else if name != "REGEXP_COUNT" && count == occurrence {
      let selected = if group < m.groups.length() {
        m.groups[group]
      } else {
        None
      }
      return Some(
        match selected {
          None => if name == "REGEXP_INSTR" { Int(0) } else { Null }
          Some((first, last)) =>
            if name == "REGEXP_INSTR" {
              Int(
                regex_text(
                  bytes,
                  0,
                  if return_option == 1 {
                    last
                  } else {
                    first
                  },
                ).length() +
                1,
              )
            } else {
              String(regex_text(bytes, first, last))
            }
        },
      )
    }
    at = if a == b { @regex.next_boundary(bytes, b) } else { b }
  }
  Some(
    match name {
      "REGEXP_LIKE" => Bit(false)
      "REGEXP_COUNT" => Int(count)
      "REGEXP_INSTR" => Int(0)
      "REGEXP_SUBSTR" => Null
      _ => {
        output.write_bytes(bytes[copied:bytes.length()])
        let result = if changed {
          @utf8.decode_lossy(output.to_bytes())
        } else {
          source
        }
        let target : @types.SqlType = match e.ty {
          Char(n, c) | VarChar(Some(n), c) => VarChar(Some(n), c)
          NChar(n, c) | NVarChar(Some(n), c) => NVarChar(Some(n), c)
          _ => e.ty
        }
        @types.cast(
          String(result),
          NVarChar(None, @types.default_collation),
          target,
        )
      }
    },
  )
}
