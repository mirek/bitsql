///|
/// Native function and method mutation use different advanced accessors.
/// None means the original native value (including allocation) is retained.
pub fn native_modify_path(
  doc : String,
  path : String,
  is_method : Bool,
  empty_storage : Bool,
) -> String? raise JsonError {
  let p = parse_path(path, allow_append=true, native=true)
  for step in p.steps {
    if is_method &&
      step is Elements(ranges) &&
      ranges.any(r => r.0 < 0L && r.1 >= 0L) {
      raise JsonError(13660, 1, ADVANCED_REVERSED)
    }
    let advanced = match step {
      AnyKey | AnyIndex | Range(_, _) => true
      Elements(ranges) => ranges.any(r => r.0 != r.1)
      _ => false
    }
    if advanced {
      raise JsonError(
        13660, 5, "JsonModify not yet supported for advanced JSON array accessors.",
      )
    }
  }
  if p.steps.is_empty() {
    return Some(path)
  }
  if is_method && empty_storage && !p.strict && !p.append {
    raise JsonError(
      22020, 1, "Internal Error: Tried to access an expired large object.",
    )
  }
  let steps : Array[Step] = []
  let out = StringBuilder()
  if p.append {
    out.write_string("append ")
  }
  if p.strict {
    out.write_string("strict ")
  }
  out.write_string("$")
  for i, original in p.steps {
    let parent = select(doc, { strict: false, append: false, steps, }, 1)
    let step = match original {
      Elements([(-1L, -1L)]) if !is_method => Index(0)
      Elements(_) => {
        if p.strict {
          raise JsonError(13608, 5, MISSING_MESSAGE)
        }
        return None
      }
      other => other
    }
    steps.push(step)
    match step {
      Key(k) => {
        out.write_string(".")
        out.write_string(quote(k))
      }
      Index(n) => out.write_string("[\{n}]")
      _ => () // advanced ranges were rejected above
    }
    let hit = select(doc, { strict: false, append: false, steps, }, 1)
    if hit is None {
      if p.strict {
        raise JsonError(13608, 5, MISSING_MESSAGE)
      }
      if step is Key(_) && parent is Some({ kind: Object, .. }) {
        if i == p.steps.length() - 1 {
          // The existing mutation engine handles insertion/deletion here.
          return Some(out.to_string())
        }
        if p.append {
          raise JsonError(
            13656, 8, "JSON data type cannot be used when its feature switch is off. ",
          )
        }
      }
      return None
    }
    if i == p.steps.length() - 1 &&
      p.append &&
      p.strict &&
      step is Index(_) &&
      hit is Some({ kind, .. }) &&
      !(kind is Array) {
      raise JsonError(
        13621, 3, "Array cannot be found in the specified JSON path.",
      )
    }
  }
  Some(out.to_string())
}
