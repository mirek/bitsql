///|
/// A TDS transaction manager request (MS-TDS 2.2.6.9), as tedious sends it
/// for beginTransaction / commitTransaction / rollbackTransaction /
/// saveTransaction (mssql's Transaction).
pub(all) enum TmRequest {
  /// Isolation level (0 = no change, 1 READ UNCOMMITTED … 5 SNAPSHOT), name.
  Begin(Int, String)
  /// Name; `begin_new` = (isolation, name) when fBeginXact is set.
  Commit(String, begin_new~ : (Int, String)?)
  Rollback(String, begin_new~ : (Int, String)?)
  Save(String)
  /// TM_GET_DTC_ADDRESS, TM_PROPAGATE_XACT, TM_PROMOTE_XACT (distributed).
  Unsupported(Int)
} derive(Debug, Eq)

///|
/// Transaction names are B_VARCHAR whose length byte tedious writes as a
/// byte count (name.length * 2); SQL Server accepts it (captured: corpus
/// tm/named-and-savepoint).
fn read_tm_name(r : Reader) -> String raise TdsError {
  let n = r.u8()
  r.ucs2(n / 2)
}

///|
fn read_begin_new(r : Reader) -> (Int, String)? raise TdsError {
  if r.at_end() {
    return None
  }
  if (r.u8() & 1) == 0 || r.at_end() {
    return None
  }
  let level = r.u8()
  Some((level, if r.at_end() { "" } else { read_tm_name(r) }))
}

///|
pub fn decode_tm(payload : BytesView) -> (Headers, TmRequest) raise TdsError {
  let r = Reader::new(payload)
  let headers = read_all_headers(r)
  let req : TmRequest = match r.u16le() {
    5 => {
      let level = r.u8()
      Begin(level, if r.at_end() { "" } else { read_tm_name(r) })
    }
    7 => {
      let name = read_tm_name(r)
      Commit(name, begin_new=read_begin_new(r))
    }
    8 => {
      let name = read_tm_name(r)
      Rollback(name, begin_new=read_begin_new(r))
    }
    9 => Save(read_tm_name(r))
    other => Unsupported(other)
  }
  (headers, req)
}
