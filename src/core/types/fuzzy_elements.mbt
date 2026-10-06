///|
/// Fuzzy matching operates on normalized characters, not a string sort key:
/// retain punctuation and U+200B (but remove soft hyphen), combine accents with their
/// base, expand ligatures, and preserve UTF-16 surrogate halves.
pub fn fuzzy_elements(s : String, c : Collation) -> Array[Array[Int]] {
  let text = s.trim_end(chars=" ").to_owned()
  let text = if c.turkish() && c.kind is Linguistic {
    turkish_input(text)
  } else {
    text
  }
  let out : Array[Array[Int]] = []
  let elements : Array[Int] = []
  for j in 0..<text.length() {
    let raw = text[j].to_int()
    if c.kind != Linguistic {
      out.push([raw])
      continue
    }
    if raw == 0xAD {
      continue
    }
    elements.clear()
    let expansion = match raw {
      0xFB00 => "ff"
      0xFB01 => "fi"
      0xFB02 => "fl"
      0xFB03 => "ffi"
      0xFB04 => "ffl"
      0xFB05 | 0xFB06 => "st"
      _ => ""
    }
    if !expansion.is_empty() {
      for unit in expansion.iter() {
        push_collation_unit(elements, unit.to_int(), c, true)
      }
    } else {
      push_collation_unit(
        elements,
        if !c.turkish() && raw == 0x131 && !c.accent_sensitive {
          0x69
        } else if !c.accent_sensitive && raw == 0xF8 {
          0x6F
        } else if !c.accent_sensitive && raw == 0xD8 {
          0x4F
        } else {
          raw
        },
        c,
        true,
      )
    }
    for e in elements {
      if e < 0 {
        if c.accent_sensitive {
          if out.is_empty() {
            out.push([0, e])
          } else {
            out[out.length() - 1].push(e)
          }
        }
      } else {
        let mut mask = -1
        if !c.case_sensitive {
          mask = mask & -13
        }
        if !c.kana_sensitive {
          mask = mask & -3
        }
        if !c.width_sensitive {
          mask = mask & -2
        }
        out.push([e & mask])
      }
    }
  }
  // Accent order does not affect the character's fuzzy comparison key.
  for key in out {
    key.sort()
  }
  out
}
