///|
/// Captured Turkish contractions; do not apply general NFC (ö and İ differ
/// from their decomposed spellings in the oracle's Turkish sort tables).
fn turkish_input(s : String) -> String {
  let out = StringBuilder()
  let mut i = 0
  while i < s.length() {
    let u = s.code_unit_at(i).to_int()
    let next = if i + 1 < s.length() {
      s.code_unit_at(i + 1).to_int()
    } else {
      -1
    }
    let combined = match (u, next) {
      (0x63, 0x327) => 0xE7
      (0x43, 0x327) => 0xC7
      (0x67, 0x306) => 0x11F
      (0x47, 0x306) => 0x11E
      (0x73, 0x327) => 0x15F
      (0x53, 0x327) => 0x15E
      (0x75, 0x308) => 0xFC
      (0x55, 0x308) => 0xDC
      _ => -1
    }
    out.write_char((if combined < 0 { u } else { combined }).unsafe_to_char())
    i += if combined < 0 { 1 } else { 2 }
  }
  out.to_string()
}

///|
fn push_collation_unit(
  out : Array[Int],
  raw : Int,
  c : Collation,
  word_sort : Bool,
) -> Unit {
  if !c.turkish() {
    push_unit_elements(out, raw, c.version, word_sort)
    return
  }
  if raw == 0xFB03 {
    for u in [0x66, 0x66, 0x69] {
      push_unit_elements(out, u, c.version, word_sort)
    }
    return
  }
  let special : (Int, Bool)? = match raw {
    0x49 => Some((letter_primary('i') - 1, true))
    0x131 => Some((letter_primary('i') - 1, false))
    0x130 => Some((letter_primary('i'), true))
    0xC7 | 0xE7 => Some((letter_primary('c') + 1, raw == 0xC7))
    0x11E | 0x11F => Some((letter_primary('g') + 1, raw == 0x11E))
    0x15E | 0x15F => Some((letter_primary('s') + 1, raw == 0x15E))
    0xD6 | 0xF6 => Some((letter_primary('o') + 1, raw == 0xD6))
    0xDC | 0xFC => Some((letter_primary('u') + 1, raw == 0xDC))
    _ => None
  }
  match special {
    Some((primary, upper)) =>
      out.push(pack_element(primary, if upper { 2 } else { 0 }, 0))
    None => push_unit_elements(out, raw, c.version, word_sort)
  }
}
