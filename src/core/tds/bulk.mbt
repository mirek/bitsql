///|
/// A column announced in a BulkLoad COLMETADATA token.
pub(all) struct BulkColumn {
  name : String
  type_info : TypeInfo
  nullable : Bool
} derive(Debug)

///|
/// Decodes a BulkLoad (0x07) message as tedious sends it: COLMETADATA, ROW
/// tokens with RPC-style values, then DONE. No ALL_HEADERS.
pub fn decode_bulk_load(
  payload : BytesView,
) -> (Array[BulkColumn], Array[Array[WireValue]]) raise TdsError {
  let r = Reader::new(payload)
  if r.u8() != 0x81 {
    raise Malformed("bulk load must start with COLMETADATA")
  }
  let n = r.u16le()
  let columns = []
  for _ in 0..<n {
    r.skip(4) // UserType
    let flags = r.u16le()
    // text/ntext/image (with a table name) are rejected by read_type_info
    let ti = read_type_info(r)
    columns.push({
      name: r.b_varchar(),
      type_info: ti,
      nullable: (flags & 1) != 0,
    })
  }
  let rows = []
  while !r.at_end() {
    match r.u8() {
      0xD1 => rows.push(columns.map(c => read_value(r, c.type_info)))
      0xFD => break
      t => raise Malformed("unexpected bulk load token \{t}")
    }
  }
  (columns, rows)
}
