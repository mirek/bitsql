///|
/// ALTER INDEX { name | ALL } ON t { DISABLE | REBUILD [WITH (...)] |
/// REORGANIZE }. Captured (msduck-runs index-catalog #018/#019, corpus
/// tail/catalog-alter-index): completion CurCmd 337; a missing table is
/// 1088 state 9, a missing index 2727 class 11 (both end the batch). A
/// disabled nonclustered index holds no rows and enforces nothing (a
/// duplicate in a disabled unique index is accepted, REBUILD then fails
/// with 1505 + 3621); REORGANIZE of a disabled index is 1973; REBUILD
/// enables it. Disabling a clustered index (which disables the table and
/// its other indexes) and SET (...) raise emulator errors.
fn Session::exec_alter_index(
  self : Session,
  index : @ast.Ident?,
  table : @ast.ObjectName,
  action : String,
  options : Array[@ast.OptionKV],
) -> Unit raise {
  self.cur_cmd = 337
  guard self.find_table(table) is Some((scope, t)) else {
    self.cur_cmd = 253
    raise @types.sql_error(
      1088,
      "Cannot find the object \"\{object_text(table)}\" because it does not exist or you do not have permissions.",
      state=9,
    )
  }
  let targets : Array[Int] = match index {
    None => (0).until(t.indexes.length()).collect()
    Some(name) =>
      match
        t.indexes.search_by(ix => ix.name.to_lower() == name.name.to_lower()) {
        Some(k) => [k]
        None => {
          self.cur_cmd = 253
          raise @types.sql_error(
            2727,
            "Cannot find index '\{name.name}'.",
            severity=11,
          )
        }
      }
  }
  let indexes = t.indexes.copy()
  match action {
    "DISABLE" =>
      for k in targets {
        if indexes[k].clustered {
          raise @types.not_supported(
            "ALTER INDEX ... DISABLE of a clustered index",
          )
        }
        indexes[k] = { ..indexes[k], disabled: true, }
      }
    "REBUILD" => {
      let mut fill_factor : Int? = None
      for o in options {
        match o.name {
          "FILLFACTOR" =>
            fill_factor = Some(
              @string.parse_int(o.value.unwrap_or("0")) catch {
                _ => 0
              },
            )
          "ONLINE" | "MAXDOP" | "SORT_IN_TEMPDB" => ()
          other =>
            raise @types.not_supported("ALTER INDEX REBUILD option \{other}")
        }
      }
      let rows = self.db_of(scope).rows(t.id)
      for k in targets {
        let ix = {
          ..indexes[k],
          disabled: false,
          fill_factor: fill_factor.unwrap_or(indexes[k].fill_factor),
        }
        if ix.unique && indexes[k].disabled {
          // its errors complete with CurCmd 253 (captured)
          self.cur_cmd = 253
          self.check_unique_build(scope, t, ix, rows, false)
          self.cur_cmd = 337
        }
        indexes[k] = ix
      }
    }
    "REORGANIZE" => {
      if !options.is_empty() {
        raise @types.not_supported("ALTER INDEX REORGANIZE WITH options")
      }
      for k in targets {
        if indexes[k].disabled {
          self.cur_cmd = 253
          raise @types.sql_error(
            1973,
            "Cannot perform the specified operation on disabled index '\{indexes[k].name}' on table '\{object_text(table)}'.",
          )
        }
      }
    }
    _ => raise @types.not_supported("ALTER INDEX ... \{action}")
  }
  self.write(
    scope,
    self.db_of(scope).alter_table({ ..t, indexes, modified: self.rt.now, }),
  )
  self.rt.rowcount = 0
  self.done(337)
}
