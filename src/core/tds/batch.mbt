///|
/// Transaction descriptor from the ALL_HEADERS stream (MS-TDS 2.2.5.3).
pub(all) struct Headers {
  transaction_descriptor : UInt64
  outstanding_requests : Int64
} derive(Debug, Eq)

///|
/// Reads ALL_HEADERS at the start of SQLBatch / RPC payloads. TDS 7.2+
/// clients always send it.
pub fn read_all_headers(r : Reader) -> Headers raise TdsError {
  let total = r.u32le().to_int()
  if total < 4 || total - 4 > r.remaining() {
    raise Malformed("ALL_HEADERS length \{total}")
  }
  let mut descriptor = 0UL
  let mut outstanding = 1L
  let mut left = total - 4
  while left > 0 {
    let len = r.u32le().to_int()
    if len < 6 || len > left {
      raise Malformed("header length \{len}")
    }
    let ty = r.u16le()
    if ty == 2 && len == 18 {
      descriptor = r.u64le()
      outstanding = r.u32le()
    } else {
      r.skip(len - 6)
    }
    left -= len
  }
  { transaction_descriptor: descriptor, outstanding_requests: outstanding, }
}

///|
pub(all) struct SqlBatch {
  headers : Headers
  text : String
} derive(Debug)

///|
pub fn decode_sql_batch(payload : BytesView) -> SqlBatch raise TdsError {
  let r = Reader::new(payload)
  let headers = read_all_headers(r)
  if r.remaining() % 2 != 0 {
    raise Malformed("odd-length UCS-2 batch text")
  }
  let text = r.ucs2(r.remaining() / 2)
  { headers, text, }
}
