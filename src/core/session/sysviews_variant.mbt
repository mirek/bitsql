// Catalog views with sql_variant columns: sys.identity_columns and
// sys.sequences. The variant values have the column's / sequence's type as
// their base type (captured: properties/identity-columns.sql,
// properties/sequences-catalog.sql).

///|
/// An integer as a sql_variant of integer-like type `ty` (int family or
/// decimal(p, 0)).
fn int_variant(n : Int64, ty : @types.SqlType) -> @types.Value {
  let v = @types.cast(BigInt(n), BigInt, ty) catch { _ => return Null }
  Variant(v, ty)
}

///|
/// Rows of the catalog views defined in this file (empty for others).
fn Session::variant_view_rows(self : Session, key : String) -> Array[VRow] {
  let db = self.db_of(0)
  let out : Array[VRow] = []
  match key {
    "sys.identity_columns" =>
      for t in db.tables() {
        for c in t.columns {
          guard c.identity is Some(id) else { continue }
          let r = column_row(t.id, c)
          r["seed_value"] = int_variant(id.seed, c.ty)
          r["increment_value"] = int_variant(id.increment, c.ty)
          r["last_value"] = match self.server.idents.get(self.ident_key(t)) {
            Some(last) => int_variant(last, c.ty)
            None => Null
          }
          r["is_not_for_replication"] = b(false)
          r["is_sparse"] = b(false)
          r["is_column_set"] = b(false)
          r["is_xml_document"] = b(false)
          r["xml_collection_id"] = i(0)
          r["rule_object_id"] = i(0)
          r["is_filestream"] = b(false)
          r["is_replicated"] = b(false)
          r["is_non_sql_subscribed"] = b(false)
          r["is_merge_published"] = b(false)
          r["is_dts_replicated"] = b(false)
          r["is_hidden"] = b(false)
          r["is_masked"] = b(false)
          r["is_data_deletion_filter_column"] = b(false)
          r["is_dropped_ledger_column"] = b(false)
          out.push(r)
        }
      }
    "sys.sequences" =>
      for m in db.modules() {
        guard m.kind is Sequence else { continue }
        guard self.server.seqs.get(seq_key(self.rt.database, m.id)) is Some(s) else {
          continue
        }
        let r = object_row(module_obj(db, m))
        let (st, ut, _, p, sc) = type_ids(s.ty)
        r["is_ms_shipped"] = b(false)
        r["is_published"] = b(false)
        r["is_schema_published"] = b(false)
        r["start_value"] = int_variant(s.start, s.ty)
        r["increment"] = int_variant(s.increment, s.ty)
        r["minimum_value"] = int_variant(s.min, s.ty)
        r["maximum_value"] = int_variant(s.max, s.ty)
        r["is_cycling"] = b(s.cycle)
        r["is_cached"] = b(s.cache is Some(_))
        r["cache_size"] = match s.cache {
          Some(n) if s.cache_sized => i(n)
          _ => Null
        }
        r["system_type_id"] = TinyInt(st)
        r["user_type_id"] = i(ut)
        r["precision"] = TinyInt(p)
        r["scale"] = TinyInt(sc)
        r["current_value"] = int_variant(s.current.unwrap_or(s.start), s.ty)
        // exhausted once the last value before the bound was handed out
        // (captured: MAXVALUE 11 INCREMENT BY 2 after 11)
        r["is_exhausted"] = b(
          !s.cycle &&
          (match s.current {
            Some(c) =>
              if s.increment > 0L {
                c > s.max - s.increment
              } else {
                c < s.min - s.increment
              }
            None => false
          }),
        )
        r["last_used_value"] = match s.current {
          Some(c) => int_variant(c, s.ty)
          None => Null
        }
        out.push(r)
      }
    _ => ()
  }
  out
}
