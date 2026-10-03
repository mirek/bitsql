// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) for gzip trailers.

///|
let crc_table : FixedArray[UInt] = {
  let t = FixedArray::make(256, 0U)
  for n in 0..<256 {
    let mut c = n.reinterpret_as_uint()
    for _ in 0..<8 {
      c = if (c & 1U) != 0U { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
    t[n] = c
  }
  t
}

///|
/// CRC-32 of `data`.
pub fn crc32(data : BytesView) -> UInt {
  let mut c = 0xFFFFFFFFU
  for b in data {
    c = crc_table[((c ^ b.to_uint()) & 0xFFU).reinterpret_as_int()] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFFU
}
