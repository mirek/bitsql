///|
/// JSON_CONTAINS keeps empty wildcard selections distinct from missing paths,
/// and does not stop at JSON nulls as scalar extraction does.
pub fn contains_values(
  doc : String,
  path : String,
  ordered? : Bool = false,
) -> Array[OpenJsonRow]? raise JsonError {
  let p = parse_path(path, native=true)
  let scanner = root_scanner(doc, 1, false)
  let start = scanner.pos
  let kind = scanner.skip_value(0)
  let mut hits : Array[Hit] = [{ start, end: scanner.pos, kind, }]
  for step in p.steps {
    let next : Array[Hit] = []
    let mut resolved = false
    for hit in hits {
      let children : Array[(String, Hit)] = []
      let compatible = match (step, hit.kind) {
        (Key(_) | AnyKey, Object) => true
        (Index(_) | AnyIndex | Range(_, _) | Elements(_), Array) => true
        _ => false
      }
      if !compatible {
        if p.strict {
          return None
        }
        continue
      }
      let s : Scanner = { text: doc, pos: hit.start + 1, doc_state: 1, }
      s.ws()
      let close = if hit.kind is Object { 0x7D } else { 0x5D }
      while s.peek() != close {
        let key = if hit.kind is Object {
          let key = s.string_value()
          s.ws()
          s.expect(0x3A)
          s.ws()
          key
        } else {
          ""
        }
        let start = s.pos
        let kind = s.skip_value(0)
        children.push((key, { start, end: s.pos, kind, }))
        s.ws()
        if s.peek() == close {
          break
        }
        s.expect(0x2C)
        s.ws()
      }
      if p.strict {
        let count = children.length().to_int64()
        let outside = match step {
          Range(_, hi) => hi >= count
          Elements(ranges) =>
            ranges.any(r => {
              r.0 >= count ||
              r.1 >= count ||
              (count == 0L && (r.0 < 0L || r.1 < 0L))
            })
          _ => false
        }
        if outside {
          return None
        }
      }
      let mut matched = false
      let positions : Array[Int] = []
      if ordered && step is Elements(ranges) {
        for r in ranges {
          let count = children.length().to_int64()
          let lo = (if r.0 < 0L { count - 1L } else { r.0 }).max(0L)
          let hi = (if r.1 < 0L { count - 1L } else { r.1 }).min(count - 1L)
          if lo <= hi {
            for i in lo.to_int()..<=hi.to_int() {
              positions.push(i)
            }
          }
        }
      } else {
        for i in 0..<children.length() {
          positions.push(i)
        }
      }
      for i in positions {
        let child = children[i]
        let take = match step {
          Key(k) => !matched && child.0 == k
          AnyKey | AnyIndex => true
          Index(n) => i == n
          Range(lo, hi) => i.to_int64() >= lo && i.to_int64() <= hi
          Elements(ranges) =>
            ranges.any(r => {
              let lo = if r.0 < 0L {
                children.length().to_int64() - 1L
              } else {
                r.0
              }
              let hi = if r.1 < 0L {
                children.length().to_int64() - 1L
              } else {
                r.1
              }
              i.to_int64() >= lo && i.to_int64() <= hi
            })
        }
        if take {
          matched = true
          next.push(child.1)
        }
      }
      let empty_range = match step {
        Elements(ranges) =>
          ranges.any(r => {
            let count = children.length().to_int64()
            let lo = if r.0 < 0L { count - 1L } else { r.0 }
            let hi = if r.1 < 0L { count - 1L } else { r.1 }
            lo > hi && hi >= 0L && lo < count
          })
        _ => false
      }
      if matched || empty_range || step is (AnyIndex | AnyKey) {
        resolved = true
      } else if p.strict {
        return None
      }
    }
    if !resolved {
      return None
    }
    hits = next
  }
  Some(
    hits.map(h => { key: "", value: scalar_text(doc, h), ty: h.kind.code(), }),
  )
}
