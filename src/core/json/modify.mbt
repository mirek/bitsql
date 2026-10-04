///|
/// JSON_MODIFY (captured: harness/corpus/json2/json-modify*.sql). The
/// document is edited as text: everything outside the touched member keeps
/// its spelling and whitespace.
///
/// - replace: the value's text is swapped for the new one;
/// - insert (lax, missing last key of an existing object): `,"k":v` (no
///   comma into an empty object) right before the closing brace;
/// - delete (lax, NULL value, object member): the member plus its preceding
///   comma, or plus its following comma when it is the first member;
/// - NULL into an array element or under strict: `null`;
/// - append: the value goes before the target array's `]`; a missing last
///   key gets `"k":[v]`; a non-array target is left alone.
/// Lax paths through missing or mistyped steps leave the text unchanged;
/// strict ones raise 13608.

///|
/// JSON_MODIFY's path: the common grammar plus `append`; advanced
/// accessors that select several values are 13660 state 4 (captured: `[*]`,
/// `.*`, `[0 to 1]`; `[0 to 0]` is an index and `[last]` keeps its own 13660).
fn parse_modify_path(path : String) -> Path raise JsonError {
  let p = parse_path(path, allow_append=true)
  if p.is_multi() {
    raise JsonError(
      13660, 4, "JsonModify not yet supported for advanced JSON array accessors.",
    )
  }
  p
}

///|
/// Where a path step landed inside its container.
priv struct Slot {
  /// Position of the container's closing `}` / `]`.
  close : Int
  /// Whether the container has any member.
  nonempty : Bool
  /// The member (key or element) start, value span and adjacent commas
  /// (-1 when absent); `start` is -1 when the step was not found.
  start : Int
  value_start : Int
  value_end : Int
  comma_before : Int
  comma_after : Int
}

///|
/// Finds `step` inside the container at `pos` (an object for keys, an array
/// for indexes; the caller checked the kind). The text is already valid.
fn find_in(doc : String, pos : Int, step : Step) -> Slot raise JsonError {
  let s : Scanner = { text: doc, pos: pos + 1, doc_state: 7, }
  let is_obj = step is Key(_)
  let close_ch = if is_obj { 0x7D } else { 0x5D }
  s.ws()
  let mut found_start = -1
  let mut vstart = -1
  let mut vend = -1
  let mut comma_before = -1
  let mut comma_after = -1
  let mut nonempty = false
  let mut prev_comma = -1
  let mut idx = 0
  while s.peek() != close_ch {
    nonempty = true
    let member_start = s.pos
    let mut hit = false
    if is_obj {
      let key = s.string_value()
      s.ws()
      s.expect(0x3A)
      s.ws()
      hit = found_start < 0 && step is Key(k) && k == key
    } else {
      hit = found_start < 0 && step is Index(i) && i == idx
    }
    let value_start = s.pos
    ignore(s.skip_value(1))
    if hit {
      found_start = member_start
      vstart = value_start
      vend = s.pos
      comma_before = prev_comma
    }
    s.ws()
    if s.peek() == 0x2C {
      if hit {
        comma_after = s.pos
      }
      prev_comma = s.pos
      s.pos += 1
      s.ws()
    }
    idx += 1
  }
  {
    close: s.pos,
    nonempty,
    start: found_start,
    value_start: vstart,
    value_end: vend,
    comma_before,
    comma_after,
  }
}

///|
pub fn quote(s : String) -> String {
  let buf = StringBuilder()
  buf.write_char('"')
  for i in 0..<s.length() {
    let u = s.code_unit_at(i).to_int()
    match u {
      0x22 => buf.write_string("\\\"")
      0x5C => buf.write_string("\\\\")
      0x2F => buf.write_string("\\/")
      0x08 => buf.write_string("\\b")
      0x0C => buf.write_string("\\f")
      0x0A => buf.write_string("\\n")
      0x0D => buf.write_string("\\r")
      0x09 => buf.write_string("\\t")
      _ =>
        if u < 0x20 {
          let h = u.to_string(radix=16)
          buf.write_string("\\u")
          for _ in h.length()..<4 {
            buf.write_char('0')
          }
          buf.write_string(h)
        } else {
          buf.write_char(u.unsafe_to_char())
        }
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
fn splice(doc : String, start : Int, end : Int, text : String) -> String {
  doc.unsafe_substring(start=0, end=start) +
  text +
  doc.unsafe_substring(start=end, end=doc.length())
}

///|
/// JSON_MODIFY(doc, path, value): `value` is the new value's JSON text
/// (already formatted and escaped) or None for SQL NULL.
pub fn json_modify(
  doc : String,
  path : String,
  value : String?,
) -> String raise JsonError {
  let p = parse_modify_path(path)
  // captured: the first character is checked before the rest of the text
  // ('not json' fails at 'n', position 0)
  let s0 : Scanner = { text: doc, pos: 0, doc_state: 7, }
  s0.ws()
  if !(s0.peek() is (0x7B | 0x5B)) {
    raise s0.fail()
  }
  validate_document(doc, 7)
  if p.steps.is_empty() && !p.append {
    raise JsonError(
      13619, 1, "Unsupported JSON path found in argument 2 of JSON_MODIFY.",
    )
  }
  let missing = () => {
    if p.strict {
      raise JsonError(13608, 2, MISSING_MESSAGE)
    } else {
      doc
    }
  }
  let s : Scanner = { text: doc, pos: 0, doc_state: 7, }
  s.ws()
  // position of the current container / value
  let mut pos = s.pos
  let mut last : Slot? = None
  for i, step in p.steps {
    let c = doc.code_unit_at(pos).to_int()
    let ok = match step {
      Key(_) => c == 0x7B
      Index(_) => c == 0x5B
      _ => false
    }
    if !ok {
      return missing()
    }
    let slot = find_in(doc, pos, step)
    if slot.start < 0 {
      if i < p.steps.length() - 1 {
        return missing()
      }
      // missing last step
      match step {
        Key(k) if !p.strict => {
          let v = match value {
            None => if p.append { Some("[null]") } else { None }
            Some(t) => Some(if p.append { "[" + t + "]" } else { t })
          }
          match v {
            None => return doc
            Some(t) => {
              let piece = (if slot.nonempty { "," } else { "" }) +
                quote(k) +
                ":" +
                t
              return splice(doc, slot.close, slot.close, piece)
            }
          }
        }
        _ => return missing()
      }
    }
    pos = slot.value_start
    last = Some(slot)
  }
  let text = value.unwrap_or("null")
  if p.append {
    let c = doc.code_unit_at(pos).to_int()
    if c != 0x5B {
      // captured: msduck json-constructors#035
      if p.strict {
        raise JsonError(
          13621, 1, "Array cannot be found in the specified JSON path.",
        )
      }
      return doc
    }
    let s2 : Scanner = { text: doc, pos, doc_state: 7, }
    ignore(s2.skip_value(0))
    let close = s2.pos - 1
    let s3 : Scanner = { text: doc, pos: pos + 1, doc_state: 7, }
    s3.ws()
    let empty = s3.pos == close
    return splice(doc, close, close, (if empty { "" } else { "," }) + text)
  }
  guard last is Some(slot) else { return doc }
  if value is None && !p.strict && p.steps[p.steps.length() - 1] is Key(_) {
    // delete the member
    if slot.comma_before >= 0 {
      return splice(doc, slot.comma_before, slot.value_end, "")
    }
    if slot.comma_after >= 0 {
      return splice(doc, slot.start, slot.comma_after + 1, "")
    }
    return splice(doc, slot.start, slot.value_end, "")
  }
  splice(doc, slot.value_start, slot.value_end, text)
}
