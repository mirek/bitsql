///|
/// ALTER INDEX { name | ALL } ON t { DISABLE | REBUILD [WITH (...)] |
/// REORGANIZE }. Captured (msduck-runs index-catalog #018/#019, corpus
/// tail/catalog-alter-index): completion CurCmd 337; a missing table is
/// 1088 state 9, a missing index 2727 class 11 (both end the batch). A
/// disabled nonclustered index holds no rows and enforces nothing (a
/// duplicate in a disabled unique index is accepted, REBUILD then fails
/// with 1505 + 3621); REORGANIZE of a disabled index is 1973; REBUILD
/// enables it. A disabled clustered index prevents query plans; its dependent
/// indexes remain disabled after rebuilding the clustered index.
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
  let has_json = targets.any(k => indexes[k].json is Some(_))
  if action == "SET" && has_json {
    self.cur_cmd = 253
    raise @types.sql_error(
      13688, "One or more of the specified ALTER INDEX options is invalid for a JSON index.",
    )
  }
  if action == "REBUILD" &&
    has_json &&
    t.indexes.any(ix => ix.clustered && ix.disabled) {
    self.cur_cmd = 253
    if index is None {
      if disabled_cluster_error(t, object_text(table)) is Some(e) {
        raise e
      }
    } else {
      let k = targets[0]
      raise @types.sql_error(
        1987,
        "Cannot alter JSON index '\{indexes[k].name}' on table '\{object_text(table)}' because its clustered index is disabled.",
      )
    }
  }
  match action {
    "DISABLE" =>
      if targets.any(k => indexes[k].clustered) {
        for k, ix in indexes {
          if !ix.clustered && !ix.disabled {
            self.info(
              3750,
              1,
              "Warning: Index '\{ix.name}' on table '\{object_text(table)}' was disabled as a result of disabling the clustered index on the table.",
              self.stmt_line,
            )
          }
          indexes[k] = { ..ix, disabled: true, }
        }
      } else {
        for k in targets {
          indexes[k] = { ..indexes[k], disabled: true, }
        }
      }
    "REBUILD" => {
      let mut fill_factor : Int? = None
      let mut compression : Int? = None
      for o in options {
        match o.name {
          "FILLFACTOR" =>
            fill_factor = Some(
              @string.parse_int(o.value.unwrap_or("0")) catch {
                _ => 0
              },
            )
          "ONLINE" if has_json && o.value.unwrap_or("").to_upper() == "ON" => {
            self.cur_cmd = 253
            raise @types.sql_error(
              153,
              "Invalid usage of the option ONLINE in the ALTER INDEX REBUILD statement.",
              state=37,
              severity=15,
            )
          }
          "DATA_COMPRESSION" if has_json =>
            compression = Some(
              match o.value.unwrap_or("").to_upper() {
                "PAGE" => 2
                "ROW" => 1
                "NONE" => 0
                other =>
                  raise @types.not_supported(
                    "ALTER INDEX DATA_COMPRESSION = \{other}",
                  )
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
          json: indexes[k].json.map(j => {
            ..j,
            compression: compression.unwrap_or(j.compression),
          }),
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

///|
fn disabled_cluster_error(
  t : @store.Table,
  display : String,
) -> @types.SqlError? {
  for ix in t.indexes {
    if ix.clustered && ix.disabled {
      return Some(
        @types.sql_error(
          8655,
          "The query processor is unable to produce a plan because the index '\{ix.name}' on table or view '\{display}' is disabled.",
        ),
      )
    }
  }
  None
}
