///|
pub(all) enum ProcRef {
  Name(String)
  Id(Int) // 10 sp_executesql, 11 sp_prepare, 12 sp_execute, 13 sp_prepexec, 15 sp_unprepare
} derive(Debug, Eq)

///|
pub(all) struct RpcParam {
  name : String // includes '@', may be empty for positional
  by_ref : Bool // OUTPUT
  default_value : Bool
  type_info : TypeInfo
  value : WireValue
} derive(Debug)

///|
pub(all) struct RpcCall {
  proc : ProcRef
  option_flags : Int
  params : Array[RpcParam]
} derive(Debug)

///|
pub(all) struct RpcRequest {
  headers : Headers
  calls : Array[RpcCall]
} derive(Debug)

///|
/// Canonical lowercase name for well-known procedure ids, so dispatch can
/// treat `Id(10)` and `Name("sp_executesql")` the same way.
pub fn ProcRef::canonical_name(self : ProcRef) -> String {
  match self {
    Name(n) => n.to_lower()
    Id(10) => "sp_executesql"
    Id(11) => "sp_prepare"
    Id(12) => "sp_execute"
    Id(13) => "sp_prepexec"
    Id(15) => "sp_unprepare"
    Id(n) => "#proc\{n}"
  }
}

///|
pub fn decode_rpc(payload : BytesView) -> RpcRequest raise TdsError {
  let r = Reader::new(payload)
  let headers = read_all_headers(r)
  let calls = []
  while !r.at_end() {
    let len = r.u16le()
    let proc = if len == 0xFFFF {
      ProcRef::Id(r.u16le())
    } else {
      ProcRef::Name(r.ucs2(len))
    }
    let option_flags = r.u16le()
    let params = []
    while !r.at_end() {
      let peek = r.data[r.pos].to_int()
      if peek == 0xFF || peek == 0xFE || peek == 0x80 {
        r.skip(1)
        break
      }
      let name = r.b_varchar()
      let status = r.u8()
      let type_info = read_type_info(r)
      let value = read_value(r, type_info)
      params.push({
        name,
        by_ref: (status & 1) != 0,
        default_value: (status & 2) != 0,
        type_info,
        value,
      })
    }
    calls.push({ proc, option_flags, params, })
  }
  { headers, calls, }
}
