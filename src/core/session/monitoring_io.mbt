///|
/// Read footprint at the materialized storage boundary. Like the allocation
/// catalogs, logical pages are modeled, not SQL Server buffer-pool events.
/// Charge each source invocation; cached arrays still constitute logical reads.
fn Session::charge_reads(self : Session, pages : Int64) -> Unit {
  if self.statement_sample is Some(sample) {
    sample.logical_reads += pages
  }
}

///|
fn Session::read_pages(
  self : Session,
  scope : Int,
  id : Int,
  rows : Array[(Int64, Array[@types.Value])],
) -> Int64 {
  if !self.server.monitoring || rows.is_empty() {
    return 0L
  }
  if scope != 2 {
    guard self.db_of(scope).table(id) is Some(t) else { return 0L }
    let fp = record_footprint(
      t,
      { cols: stored_columns(t), extra: 0, header: 4, },
      _ => true,
      rows,
      false,
    )
    return fp.data.to_int64() + fp.overflow.to_int64() + fp.lob.to_int64()
  }
  // Virtual catalog rows have no stored table. Measure their typed payload
  // and round to 8-KiB pages, with a record header and slot per row.
  guard view_defs.get(if id >= 0 { id % TEMPDB_VIEW_OFFSET } else { -1 })
    is Some(view) else {
    return 0L
  }
  let mut bytes = 0L
  for (_, row) in rows {
    bytes += 8L
    for k, c in view.columns {
      if row.get(k) is Some(v) && !(v is Null) {
        bytes += @types.variant_data_length(v, c.ty).to_int64()
      }
    }
  }
  (bytes + 8191L) / 8192L
}
