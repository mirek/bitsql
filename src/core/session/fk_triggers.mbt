// AFTER triggers of tables changed by cascading referential actions
// (captured: harness/corpus/triggers/cascade-*.sql). All cascades of the
// statement are applied first; then each changed child table fires its
// triggers, in reverse depth-first order of the cascade tree (children by
// foreign key creation order), before the statement's own triggers. A
// child fires UPDATE triggers for its cascaded updates, then DELETE
// triggers for its cascaded deletes, each with @@ROWCOUNT = all of that
// table's cascaded rows; tables the cascade did not reach do not fire.
// UPDATE() / COLUMNS_UPDATED() name the foreign key columns.

///|
/// One child table changed by a referential action of a statement.
priv struct CascadeNode {
  table : Int
  /// The foreign key whose action changed the table (sibling order).
  fk : Int
  /// The node of the table whose change triggered this one (-1: the
  /// statement's own table).
  parent : Int
  changes : Array[RowChange]
  /// Columns set by the action (the foreign key columns).
  updated : Array[Int]
}

///|
/// Rejects the trigger combinations of a cascaded change that are not
/// emulated faithfully. Called before the change is applied.
fn Session::check_cascade_triggers(
  self : Session,
  target : Target,
  f : @store.ForeignKey,
  changes : Array[RowChange],
  verb : String,
) -> Unit raise {
  let has_update = changes.iter().any(ch => ch.2 is Some(_))
  let has_delete = changes.iter().any(ch => ch.2 is None)
  let trs = []
  if has_update {
    trs.push_iter(self.table_triggers(target, OnUpdate).iter())
  }
  if has_delete {
    trs.push_iter(self.table_triggers(target, OnDelete).iter())
  }
  if trs.is_empty() {
    return
  }
  // CREATE TRIGGER (2113) and ALTER TABLE ADD (1787) keep these apart
  if trs.iter().any(x => x.0.instead_of) {
    raise @types.not_supported(
      "INSTEAD OF triggers on a table changed by a cascading referential action",
    )
  }
  // captured (cascade-merge-unique-key): a MERGE's cascade into the
  // clustered unique key of a child is split into delete + insert; the
  // child's UPDATE trigger sees empty pseudo-tables and its DELETE trigger
  // the updated rows too
  if verb == "MERGE" &&
    has_update &&
    target.table.indexes
    .iter()
    .any(ix => {
      ix.clustered &&
      ix.unique &&
      ix.columns.iter().any(c => f.columns.contains(c.0))
    }) {
    raise @types.not_supported(
      "triggers on a table whose clustered unique key a MERGE changes through a referential action",
    )
  }
}

///|
/// Firing order of cascade nodes: depth-first preorder from the
/// statement's table with children by foreign key creation order,
/// reversed (captured: cascade-delete, grandchildren before children,
/// later foreign keys first).
fn cascade_fire_order(nodes : Array[CascadeNode]) -> Array[Int] {
  let pre : Array[Int] = []
  let stack : Array[Int] = [-1]
  while stack.pop() is Some(n) {
    if n >= 0 {
      pre.push(n)
    }
    let kids = []
    for i, c in nodes {
      if c.parent == n {
        kids.push(i)
      }
    }
    kids.sort_by((a, b) => nodes[a].fk.compare(nodes[b].fk))
    // pushed last-first so the first child is visited first
    for k = kids.length() - 1; k >= 0; k = k - 1 {
      stack.push(kids[k])
    }
  }
  pre.rev_in_place()
  pre
}

///|
/// Fires the AFTER triggers of the child tables a statement changed through
/// referential actions. `pre` is the state before the statement.
fn Session::fire_cascade_triggers(
  self : Session,
  scope : Int,
  nodes : Array[CascadeNode],
  pre : @store.Db,
) -> Unit raise {
  if nodes.is_empty() || scope != 0 {
    return
  }
  for i in cascade_fire_order(nodes) {
    let n = nodes[i]
    guard self.db_of(scope).table(n.table) is Some(t) else { continue }
    let target = table_target(scope, t, t.name.to_lower())
    let olds = []
    let news = []
    let removed = []
    for ch in n.changes {
      match ch.2 {
        Some(r) => {
          olds.push(ch.1)
          news.push(r)
        }
        None => removed.push(ch.1)
      }
    }
    let count = n.changes.length().to_int64()
    if !news.is_empty() {
      self.fire_after(
        target,
        OnUpdate,
        olds,
        news,
        n.updated,
        pre,
        firing_count=count,
      )
    }
    if !removed.is_empty() {
      self.fire_after(
        target,
        OnDelete,
        removed,
        [],
        [],
        pre,
        firing_count=count,
      )
    }
  }
}
