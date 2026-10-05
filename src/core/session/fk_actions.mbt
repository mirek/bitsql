// FOREIGN KEY enforcement at statement level: referential actions (ON
// DELETE / ON UPDATE CASCADE, SET NULL, SET DEFAULT), NO ACTION checks
// against the statement's final state, and their messages. Rules from
// msduck gaps-constraints captures (referential-actions,
// update-shapes-and-computed-columns, cascade-paths, definition-errors):
//
// - an action fires for every referenced row whose key is deleted or
//   changed, even when the same key value still exists afterwards (a
//   CASE swap of 2 and 3 sets the SET NULL children to NULL);
// - children changed by SET NULL / SET DEFAULT / CASCADE UPDATE propagate
//   as updates, CASCADE DELETE as deletes, recursively;
// - NO ACTION is checked after the whole statement: a self-referencing
//   DELETE of every row succeeds; a child still referencing a key that no
//   longer exists is 547 REFERENCE (SAME TABLE REFERENCE for a
//   self-reference);
// - SET DEFAULT rows must still satisfy the FOREIGN KEY (547 FOREIGN KEY
//   naming the parent table, with the statement's verb);
// - disabled (NOCHECK) foreign keys neither act nor check.

///|
/// One changed row: (rowid, old image, new image or None when deleted).
type RowChange = (Int64, Array[@types.Value], Array[@types.Value]?)

///|
fn Session::fk_db_name(self : Session, scope : Int) -> String {
  self.scope_database(scope)
}

///|
/// 547 for a referencing row whose key has no parent row.
fn Session::fk_child_error(
  self : Session,
  scope : Int,
  verb : String,
  fk : @store.ForeignKey,
  child_id : Int,
  parent : @store.Table,
) -> @types.SqlError {
  let kind = if child_id == parent.id {
    "FOREIGN KEY SAME TABLE"
  } else {
    "FOREIGN KEY"
  }
  // multi-column keys name no column (captured: fk_m on (a, b))
  let col = if fk.ref_columns.length() == 1 {
    ", column '\{parent.columns[fk.ref_columns[0]].name}'"
  } else {
    ""
  }
  @types.sql_error(
    547,
    "The \{verb} statement conflicted with the \{kind} constraint \"\{fk.name}\". The conflict occurred in database \"\{self.fk_db_name(scope)}\", table \"\{parent.schema}.\{parent.name}\"\{col}.",
    state=0,
  )
}

///|
/// 547 for a referenced key removed while children still use it.
fn Session::fk_parent_error(
  self : Session,
  scope : Int,
  verb : String,
  fk : @store.ForeignKey,
  child : @store.Table,
) -> @types.SqlError {
  let kind = if child.id == fk.ref_table {
    "SAME TABLE REFERENCE"
  } else {
    "REFERENCE"
  }
  let col = if fk.columns.length() == 1 {
    ", column '\{child.columns[fk.columns[0]].name}'"
  } else {
    ""
  }
  @types.sql_error(
    547,
    "The \{verb} statement conflicted with the \{kind} constraint \"\{fk.name}\". The conflict occurred in database \"\{self.fk_db_name(scope)}\", table \"\{child.schema}.\{child.name}\"\{col}.",
    state=0,
  )
}

///|
/// Key equality as a unique index sees it (column collations; NULL never
/// matches).
fn fk_keys_equal(
  t : @store.Table,
  cols : Array[Int],
  a : Array[@types.Value],
  b : Array[@types.Value],
) -> Bool {
  for j, c in cols {
    if a[j] is Null || b[j] is Null {
      return false
    }
    let r = @types.compare(a[j], b[j], collation?=t.columns[c].ty.collation()) catch {
      _ => return false
    }
    if r != Some(0) {
      return false
    }
  }
  true
}

///|
/// Keys sorted for `fk_keys_equal` lookups: (key, original position) by
/// key under the column collations, then position. Keys with a NULL are
/// left out (they never match).
priv struct KeyIndex {
  keys : Array[(Array[@types.Value], Int)]
  collations : Array[@types.Collation?]
}

///|
/// None when two keys cannot be compared (the caller searches linearly).
fn KeyIndex::new(
  keys : Array[Array[@types.Value]],
  collations : Array[@types.Collation?],
) -> KeyIndex? {
  let sorted = []
  for i, k in keys {
    if !k.iter().any(v => v is Null) {
      sorted.push((k, i))
    }
  }
  let mut failed = false
  sorted.sort_by((a, b) => {
    let c = key_compare(a.0, b.0, collations) catch {
      _ => {
        failed = true
        0
      }
    }
    if c != 0 {
      c
    } else {
      a.1.compare(b.1)
    }
  })
  if failed {
    None
  } else {
    Some({ keys: sorted, collations, })
  }
}

///|
fn key_compare(
  a : Array[@types.Value],
  b : Array[@types.Value],
  collations : Array[@types.Collation?],
) -> Int raise @types.SqlError {
  for j in 0..<a.length() {
    let c = @types.compare(a[j], b[j], collation?=collations[j]).unwrap_or(0)
    if c != 0 {
      return c
    }
  }
  0
}

///|
/// The first position whose key `fk_keys_equal`s `key`, if any.
fn KeyIndex::first(self : KeyIndex, key : Array[@types.Value]) -> Int? {
  if key.iter().any(v => v is Null) {
    return None
  }
  let mut lo = 0
  let mut hi = self.keys.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let c = key_compare(self.keys[mid].0, key, self.collations) catch {
      _ => return None
    }
    if c < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo < self.keys.length() &&
    (key_compare(self.keys[lo].0, key, self.collations) catch { _ => 1 }) == 0 {
    Some(self.keys[lo].1)
  } else {
    None
  }
}

///|
/// Does `t` have a row whose `cols` equal `key` (`fk_keys_equal`)? Through
/// a unique, unfiltered index on exactly these columns when there is one
/// (its keys compare the same way); otherwise repeated lookups in one
/// table state share a sorted key index (`fk_cache`), so per-row checks of
/// a large statement do not scan the table each time.
fn Session::fk_has_key(
  self : Session,
  db : @store.Db,
  t : @store.Table,
  cols : Array[Int],
  key : Array[@types.Value],
) -> Bool {
  if key.iter().any(v => v is Null) {
    return false
  }
  for i, ix in t.indexes {
    if !ix.unique ||
      ix.filter is Some(_) ||
      ix.columns.length() != cols.length() {
      continue
    }
    let vals = []
    for c in ix.columns {
      match cols.search(c.0) {
        Some(j) => vals.push(key[j])
        None => break
      }
    }
    if vals.length() == cols.length() {
      return db.find_key(t.id, i, vals) is Some(_)
    }
  }
  guard db.table_data(t.id) is Some(data) else { return false }
  let found = self.fk_cache.search_by(e => {
    physical_equal(e.data, data) && e.table == t.id && e.columns == cols
  })
  let entry = match found {
    Some(i) => self.fk_cache[i]
    None => {
      if self.fk_cache.length() >= 8 {
        self.fk_cache.remove(0) |> ignore
      }
      let e : KeyCache = {
        data,
        table: t.id,
        columns: cols,
        uses: 0,
        index: None,
      }
      self.fk_cache.push(e)
      e
    }
  }
  entry.uses += 1
  if entry.index is None && entry.uses >= 2 {
    let rows = db.rows(t.id)
    entry.index = KeyIndex::new(
      rows.map(kv => cols.map(c => kv.1[c])),
      cols.map(c => t.columns[c].ty.collation()),
    )
  }
  match entry.index {
    Some(ix) => ix.first(key) is Some(_)
    None => {
      for kv in db.rows(t.id) {
        if fk_keys_equal(t, cols, cols.map(c => kv.1[c]), key) {
          return true
        }
      }
      false
    }
  }
}

///|
/// A sorted key index of one table state (`Session::fk_has_key`).
priv struct KeyCache {
  data : @store.TableData
  table : Int
  columns : Array[Int]
  mut uses : Int
  mut index : KeyIndex?
}

///|
/// Enabled foreign keys (of any table) referencing table `id`.
fn fk_referencing(db : @store.Db, id : Int) -> Bool {
  db
  .tables()
  .iter()
  .any(c => c.foreign_keys.iter().any(f => f.enabled && f.ref_table == id))
}

///|
/// Applies the referential actions of a statement that deleted or changed
/// rows of table `root` (`db` already holds the statement's own changes)
/// and checks the NO ACTION foreign keys of the rows it changed in other
/// tables. The statement's own NO ACTION references are checked by the
/// caller (`check_references`), row by row for OUTPUT.
fn Session::cascade_actions(
  self : Session,
  scope : Int,
  root : Int,
  db0 : @store.Db,
  changes : Array[RowChange],
  verb : String,
) -> @store.Db raise {
  let mut db = db0
  let queue : Array[(Int, Array[RowChange])] = [(root, changes)]
  // NO ACTION keys removed by cascaded changes: (fk, child id, key)
  let no_action : Array[(@store.ForeignKey, Int, Array[@types.Value])] = []
  // rows given SET DEFAULT values: (fk, child id, rowid)
  let defaults : Array[(@store.ForeignKey, Int, Int64)] = []
  let mut qi = 0
  while qi < queue.length() {
    let (tid, chs) = queue[qi]
    qi += 1
    guard db.table(tid) is Some(parent) else { continue }
    for child in db.tables() {
      for f in child.foreign_keys {
        if f.ref_table != tid || !f.enabled {
          continue
        }
        // removed keys (and their new values for updates)
        let moves : Array[(Array[@types.Value], Array[@types.Value]?)] = []
        for ch in chs {
          let (_, old, new) = ch
          let k = f.ref_columns.map(c => old[c])
          if k.iter().any(v => v is Null) {
            continue
          }
          match new {
            Some(n) => {
              let nk = f.ref_columns.map(c => n[c])
              if fk_keys_equal(parent, f.ref_columns, k, nk) {
                continue
              }
              moves.push((k, Some(nk)))
            }
            None => moves.push((k, None))
          }
        }
        if moves.is_empty() {
          continue
        }
        let deleting = moves[0].1 is None
        let action = if deleting { f.on_delete } else { f.on_update }
        if action is NoAction {
          if qi > 1 {
            for m in moves {
              no_action.push((f, child.id, m.0))
            }
          }
          continue
        }
        // child rows matching a removed key, from the state before this
        // foreign key's action (a key swap must not apply twice)
        let child_changes : Array[RowChange] = []
        let move_index = KeyIndex::new(
          moves.map(m => m.0),
          f.ref_columns.map(c => parent.columns[c].ty.collation()),
        )
        for kv in db.rows(child.id) {
          let ck = f.columns.map(c => kv.1[c])
          let hit = match move_index {
            Some(ix) => ix.first(ck)
            None =>
              moves.search_by(m => fk_keys_equal(parent, f.ref_columns, m.0, ck))
          }
          guard hit is Some(mi) else { continue }
          let new_row : Array[@types.Value]? = match (action, moves[mi].1) {
            (Cascade, None) => None
            (Cascade, Some(nk)) => {
              let r = kv.1.copy()
              for j, c in f.columns {
                r[c] = nk[j]
              }
              Some(r)
            }
            (SetNull, _) => {
              let r = kv.1.copy()
              for c in f.columns {
                r[c] = Null
              }
              Some(r)
            }
            _ => {
              // SET DEFAULT: the column default, else NULL
              let r = kv.1.copy()
              let target = table_target(scope, child, child.name.to_lower())
              for c in f.columns {
                let col = child.columns[c]
                r[c] = match col.default_ {
                  Some(d) => self.eval_default(target, col, d, kv.1)
                  None => Null
                }
              }
              Some(r)
            }
          }
          child_changes.push((kv.0, kv.1, new_row))
        }
        if child_changes.is_empty() {
          continue
        }
        let target = table_target(scope, child, child.name.to_lower())
        let ev : @ast.DmlEvent = if child_changes[0].2 is None {
          OnDelete
        } else {
          OnUpdate
        }
        if !self.table_triggers(target, ev).is_empty() {
          raise @types.not_supported(
            "triggers on a table changed by a cascading referential action",
          )
        }
        let applied : Array[RowChange] = []
        db = db.delete_rows(child.id, child_changes.map(ch => ch.0))
        for ch in child_changes {
          match ch.2 {
            None => applied.push(ch)
            Some(r) => {
              for i, c in child.columns {
                if c.computed is Some(expr) {
                  r[i] = self.eval_text(target, expr, r, c.ty)
                }
                if c.ty is RowVersion {
                  r[i] = self.next_rowversion()
                }
              }
              self.check_row(target, db, r, verb, touched=f.columns, fks=false)
              db = insert_checked(target, db, ch.0, r)
              applied.push((ch.0, ch.1, Some(r)))
              if action is SetDefault {
                defaults.push((f, child.id, ch.0))
              }
            }
          }
        }
        queue.push((child.id, applied))
      }
    }
  }
  for d in defaults {
    let (f, cid, rid) = d
    guard db.row(cid, rid) is Some(row) else { continue }
    guard db.table(f.ref_table) is Some(parent) else { continue }
    let key = f.columns.map(c => row[c])
    if key.iter().any(v => v is Null) {
      continue
    }
    if !self.fk_has_key(db, parent, f.ref_columns, key) {
      raise self.fk_child_error(scope, verb, f, cid, parent)
    }
  }
  for n in no_action {
    let (f, cid, key) = n
    guard db.table(cid) is Some(child) else { continue }
    guard db.table(f.ref_table) is Some(parent) else { continue }
    if self.fk_has_key(db, child, f.columns, key) &&
      !self.fk_has_key(db, parent, f.ref_columns, key) {
      raise self.fk_parent_error(scope, verb, f, child)
    }
  }
  db
}

///|
/// NO ACTION references of the statement's own changed rows, checked
/// against the statement's final state `db` (after cascades): a removed key
/// still used by a child row and no longer present is 547.
fn Session::check_references(
  self : Session,
  target : Target,
  db : @store.Db,
  before : Array[Array[@types.Value]],
  after : Array[Array[@types.Value]?],
  verb : String,
) -> Unit raise {
  let t = target.table
  for child in db.tables() {
    for fk in child.foreign_keys {
      if fk.ref_table != t.id || !fk.enabled {
        continue
      }
      for i, old in before {
        let action = if after[i] is None { fk.on_delete } else { fk.on_update }
        if !(action is NoAction) {
          continue
        }
        let key = fk.ref_columns.map(c => old[c])
        if key.iter().any(v => v is Null) {
          continue
        }
        // key unchanged by an UPDATE: nothing to check
        match after[i] {
          Some(new) =>
            if fk_keys_equal(
                t,
                fk.ref_columns,
                key,
                fk.ref_columns.map(c => new[c]),
              ) {
              continue
            }
          None => ()
        }
        if self.fk_has_key(db, child, fk.columns, key) &&
          !self.fk_has_key(db, t, fk.ref_columns, key) {
          raise self.fk_parent_error(target.scope, verb, fk, child)
        }
      }
    }
  }
}

///|
/// Self-referencing foreign keys of a changed row, checked against the
/// statement's final state (rows of the same statement count).
fn Session::check_self_references(
  self : Session,
  target : Target,
  db : @store.Db,
  row : Array[@types.Value],
  touched : Array[Int]?,
  verb : String,
) -> Unit raise {
  let t = target.table
  for fk in t.foreign_keys {
    if fk.ref_table != t.id || !fk.enabled {
      continue
    }
    if touched is Some(ts) && !fk.columns.iter().any(c => ts.contains(c)) {
      continue
    }
    let key = fk.columns.map(c => row[c])
    if key.iter().any(v => v is Null) {
      continue
    }
    if !self.fk_has_key(db, t, fk.ref_columns, key) {
      raise self.fk_child_error(target.scope, verb, fk, t.id, t)
    }
  }
}
