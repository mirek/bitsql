///|
/// Real storage access counts; history is independent of transaction rollback.
priv struct IndexUsage {
  counts : Array[Int64]
  times : Array[Int64?]
  seen : Array[(Int, Int64)]
}

///|
fn Session::index_access(
  self : Session,
  scope : Int,
  id : Int,
  index : Int,
  kind : Int,
) -> Unit {
  if scope is (1 | 2 | 3) {
    return
  }
  let key = (self.scope_key(scope), id, index)
  let usage = match self.server.index_usage.get(key) {
    Some(u) => u
    None => {
      let u = {
        counts: [0L, 0L, 0L, 0L],
        times: [None, None, None, None],
        seen: [(-1, -1L), (-1, -1L), (-1, -1L), (-1, -1L)],
      }
      self.server.index_usage[key] = u
      u
    }
  }
  let stamp = (self.rt.spid, self.diagnostic_statement)
  if usage.seen[kind] == stamp {
    return
  }
  usage.seen[kind] = stamp
  usage.counts[kind] += 1L
  usage.times[kind] = Some(self.rt.now)
}

///|
fn Session::index_updates(
  self : Session,
  scope : Int,
  t : @store.Table,
) -> Unit {
  if !t.indexes.any(ix => ix.clustered) {
    self.index_access(scope, t.id, 0, 3)
  }
  for ix in t.indexes {
    if !ix.disabled {
      self.index_access(scope, t.id, ix.index_id, 3)
    }
  }
}

///|
fn Server::index_usage_rows(self : Server, out : Array[VRow]) -> Unit {
  for (key, usage) in self.index_usage {
    let (database, object_id, index_id) = key
    guard self.database_id(database) is Some(database_id) else { continue }
    guard self.get_db_key(database).table(object_id) is Some(t) else {
      continue
    }
    if index_id != 0 && !t.indexes.any(ix => ix.index_id == index_id) {
      continue
    }
    let row = vrow([
      ("database_id", i(database_id)),
      ("object_id", i(object_id)),
      ("index_id", i(index_id)),
    ])
    for k, name in ["seek", "scan", "lookup", "update"] {
      row["user_" + name + "s"] = BigInt(usage.counts[k])
      row["last_user_" + name] = match usage.times[k] {
        Some(t) => dt(t)
        None => Null
      }
      row["system_" + name + "s"] = BigInt(0L)
      row["last_system_" + name] = Null
    }
    out.push(row)
  }
}
