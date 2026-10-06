///|
fn W::stmts(self : W, ss : Array[Stmt]) -> Unit {
  for s in ss {
    self.sp()
    self.stmt(s)
  }
}

///|
fn W::idents(self : W, ids : Array[Ident]) -> Unit {
  self.s("(" + ids.map(ident_text).join(" ") + ")")
}

///|
fn W::output(self : W, outs : Array[OutputClause]) -> Unit {
  for o in outs {
    self.s(" (output")
    self.select_items(o.items)
    if o.into is Some((t, cols)) {
      self.s(" (into ")
      self.table_ref(t)
      if cols.length() > 0 {
        self.sp()
        self.idents(cols)
      }
      self.close()
    }
    self.close()
  }
}

///|
fn W::set_clauses(self : W, sets : Array[SetClause]) -> Unit {
  self.s(" (set")
  for c in sets {
    self.s(" (" + (if c.mutator { "mutate" } else { assign_text(c.op) }) + " ")
    match c.target {
      SetColumn(p) => self.s(parts_text(p))
      SetVariable(v) => self.s(v)
      SetVarColumn(v, p) => self.s(v + "=" + parts_text(p))
    }
    self.sp()
    self.expr(c.value)
    self.close()
  }
  self.close()
}

///|
fn W::rows(self : W, rows : Array[Array[Expr]]) -> Unit {
  self.s(" (values")
  for r in rows {
    self.sp()
    self.exprs(r)
  }
  self.close()
}

///|
fn W::exec(self : W, e : Exec) -> Unit {
  self.open("exec")
  if e.return_var is Some(v) {
    self.s(" (returns " + v + ")")
  }
  match e.target {
    ExecProc(n) => self.atom(n.to_sexp())
    ExecVar(v) => self.atom(v)
  }
  for a in e.args {
    self.sp()
    let named = a.name is Some(_)
    if named || a.output {
      self.s("(arg")
      if a.name is Some(n) {
        self.atom(n)
      }
      self.sp()
      self.expr(a.value)
      if a.output {
        self.atom("output")
      }
      self.close()
    } else {
      self.expr(a.value)
    }
  }
  if e.with_recompile {
    self.atom("recompile")
  }
  self.close()
}

///|
fn mode_text(m : CreateMode) -> String {
  match m {
    Create => "create"
    Alter => "alter"
    CreateOrAlter => "create-or-alter"
  }
}

///|
fn ref_action_text(a : RefAction) -> String {
  match a {
    NoAction => "no-action"
    Cascade => "cascade"
    SetNull => "set-null"
    SetDefault => "set-default"
  }
}

///|
fn W::foreign_ref(self : W, r : ForeignRef) -> Unit {
  self.s("(references " + r.table.to_sexp())
  if r.columns.length() > 0 {
    self.sp()
    self.idents(r.columns)
  }
  if r.on_delete is Some(a) {
    self.s(" (on-delete " + ref_action_text(a) + ")")
  }
  if r.on_update is Some(a) {
    self.s(" (on-update " + ref_action_text(a) + ")")
  }
  self.close()
}

///|
fn W::index_cols(self : W, cols : Array[IndexColumn]) -> Unit {
  self.s("(")
  for i, c in cols {
    if i > 0 {
      self.sp()
    }
    if c.desc {
      self.s("(desc " + ident_text(c.name) + ")")
    } else {
      self.s(ident_text(c.name))
    }
  }
  self.close()
}

///|
fn clustered_text(c : Bool?) -> String {
  match c {
    Some(true) => " clustered"
    Some(false) => " nonclustered"
    None => ""
  }
}

///|
fn W::options_kv(self : W, opts : Array[OptionKV]) -> Unit {
  if opts.length() > 0 {
    self.s(" (with")
    for o in opts {
      match o.value {
        Some(v) => self.atom(o.name + "=" + v)
        None => self.atom(o.name)
      }
    }
    self.close()
  }
}

///|
fn W::column_def(self : W, c : ColumnDef) -> Unit {
  self.s("(column " + ident_text(c.name))
  if c.type_ is Some(t) {
    self.atom(t.to_sexp())
  }
  if c.computed is Some(e) {
    self.s(" (as ")
    self.expr(e)
    self.close()
  }
  if c.persisted {
    self.atom("persisted")
  }
  if c.collate is Some(x) {
    self.s(" (collate " + x.name + ")")
  }
  match c.nullable {
    Some(true) => self.atom("null")
    Some(false) => self.atom("not-null")
    None => ()
  }
  if c.identity is Some(i) {
    self.s(" (identity")
    if i.seed is Some(s) {
      self.atom(s)
    }
    if i.increment is Some(s) {
      self.atom(s)
    }
    self.close()
  }
  if c.rowguidcol {
    self.atom("rowguidcol")
  }
  if c.sparse {
    self.atom("sparse")
  }
  for k in c.constraints {
    self.sp()
    if k.name is Some(n) {
      self.s("(constraint " + ident_text(n) + " ")
    }
    match k.kind {
      ColPrimaryKey(clustered~, options~) => {
        self.s("(primary-key" + clustered_text(clustered))
        self.options_kv(options)
        self.close()
      }
      ColUnique(clustered~, options~) => {
        self.s("(unique" + clustered_text(clustered))
        self.options_kv(options)
        self.close()
      }
      ColCheck(e, ..) => {
        self.s("(check ")
        self.expr(e)
        self.close()
      }
      ColDefault(e) => {
        self.s("(default ")
        self.expr(e)
        self.close()
      }
      ColReferences(r) => self.foreign_ref(r)
    }
    if k.name is Some(_) {
      self.close()
    }
  }
  self.close()
}

///|
fn W::table_constraint(self : W, k : TableConstraint) -> Unit {
  if k.name is Some(n) {
    self.s("(constraint " + ident_text(n) + " ")
  }
  match k.kind {
    PrimaryKey(clustered~, cols, options~) => {
      self.s("(primary-key" + clustered_text(clustered) + " ")
      self.index_cols(cols)
      self.options_kv(options)
      self.close()
    }
    Unique(clustered~, cols, options~) => {
      self.s("(unique" + clustered_text(clustered) + " ")
      self.index_cols(cols)
      self.options_kv(options)
      self.close()
    }
    ForeignKey(cols, r) => {
      self.s("(foreign-key ")
      self.idents(cols)
      self.sp()
      self.foreign_ref(r)
      self.close()
    }
    Check(e, ..) => {
      self.s("(check ")
      self.expr(e)
      self.close()
    }
    DefaultFor(e, col) => {
      self.s("(default ")
      self.expr(e)
      self.s(" (for " + ident_text(col) + "))")
    }
  }
  if k.name is Some(_) {
    self.close()
  }
}

///|
fn W::table_body(self : W, b : TableBody) -> Unit {
  for c in b.columns {
    self.sp()
    self.column_def(c)
  }
  for k in b.constraints {
    self.sp()
    self.table_constraint(k)
  }
  for ix in b.indexes {
    self.s(" (index " + ident_text(ix.name) + " ")
    if ix.unique {
      self.s("unique ")
    }
    match ix.clustered {
      Some(true) => self.s("clustered ")
      Some(false) => self.s("nonclustered ")
      None => ()
    }
    self.index_cols(ix.columns)
    if ix.included.length() > 0 {
      self.s(" (include")
      for c in ix.included {
        self.s(" " + ident_text(c))
      }
      self.close()
    }
    match ix.where_ {
      Some(w) => {
        self.s(" (where ")
        self.expr(w)
        self.close()
      }
      None => ()
    }
    self.close()
  }
}

///|
fn W::params(self : W, ps : Array[Param]) -> Unit {
  if ps.length() == 0 {
    return
  }
  self.s(" (params")
  for p in ps {
    self.s(" (" + p.name + " " + p.type_.to_sexp())
    if p.varying {
      self.atom("varying")
    }
    if p.default_ is Some(d) {
      self.s(" (default ")
      self.expr(d)
      self.close()
    }
    if p.output {
      self.atom("output")
    }
    if p.read_only {
      self.atom("readonly")
    }
    self.close()
  }
  self.close()
}

///|
fn W::strs(self : W, tag : String, xs : Array[String]) -> Unit {
  if xs.length() > 0 {
    self.s(" (" + tag)
    for x in xs {
      self.atom(quote(x))
    }
    self.close()
  }
}

///|
fn W::opt_expr(self : W, tag : String, e : Expr?) -> Unit {
  self.open(tag)
  if e is Some(e) {
    self.sp()
    self.expr(e)
  }
  self.close()
}

///|
fn W::stmt(self : W, s : Stmt) -> Unit {
  match s.kind {
    Select(q) => self.query(q)
    Insert(i) => {
      self.open("insert")
      if i.ctes.length() > 0 {
        self.ctes(i.ctes)
      }
      self.top(i.top)
      self.sp()
      self.table_ref(i.target)
      if i.columns.length() > 0 {
        self.sp()
        self.idents(i.columns)
      }
      self.output(i.output)
      match i.source {
        InsertValues(rows) => self.rows(rows)
        InsertQuery(q) => {
          self.sp()
          self.query(q)
        }
        InsertExec(e) => {
          self.sp()
          self.exec(e)
        }
        DefaultValues => self.atom("default-values")
      }
      self.hints(i.options)
      self.close()
    }
    Update(u) => {
      self.open("update")
      if u.ctes.length() > 0 {
        self.ctes(u.ctes)
      }
      self.top(u.top)
      self.sp()
      self.table_ref(u.target)
      self.set_clauses(u.sets)
      self.output(u.output)
      if u.from.length() > 0 {
        self.s(" (from")
        for t in u.from {
          self.sp()
          self.table_ref(t)
        }
        self.close()
      }
      self.where_(u.where_)
      if u.current_of is Some(c) {
        self.s(" (current-of " + ident_text(c) + ")")
      }
      self.hints(u.options)
      self.close()
    }
    Delete(d) => {
      self.open("delete")
      if d.ctes.length() > 0 {
        self.ctes(d.ctes)
      }
      self.top(d.top)
      self.sp()
      self.table_ref(d.target)
      self.output(d.output)
      if d.from.length() > 0 {
        self.s(" (from")
        for t in d.from {
          self.sp()
          self.table_ref(t)
        }
        self.close()
      }
      self.where_(d.where_)
      if d.current_of is Some(c) {
        self.s(" (current-of " + ident_text(c) + ")")
      }
      self.hints(d.options)
      self.close()
    }
    Merge(m) => {
      self.open("merge")
      if m.ctes.length() > 0 {
        self.ctes(m.ctes)
      }
      self.top(m.top)
      self.sp()
      self.table_ref(m.target)
      self.s(" (using ")
      self.table_ref(m.source)
      self.close()
      self.s(" (on ")
      self.expr(m.on)
      self.close()
      for w in m.whens {
        self.s(
          match w.match_ {
            Matched => " (when-matched"
            NotMatchedByTarget => " (when-not-matched"
            NotMatchedBySource => " (when-not-matched-by-source"
          },
        )
        if w.condition is Some(c) {
          self.s(" (and ")
          self.expr(c)
          self.close()
        }
        match w.action {
          MergeUpdate(sets) => self.set_clauses(sets)
          MergeDelete => self.atom("delete")
          MergeInsert(columns~, values~, default_values~) => {
            self.s(" (insert")
            if columns.length() > 0 {
              self.sp()
              self.idents(columns)
            }
            if default_values {
              self.atom("default-values")
            } else {
              self.sp()
              self.exprs(values)
            }
            self.close()
          }
        }
        self.close()
      }
      self.output(m.output)
      self.hints(m.options)
      self.close()
    }
    Truncate(n) => self.s("(truncate " + n.to_sexp() + ")")
    CreateTable(t) => {
      self.s("(create-table " + t.name.to_sexp())
      self.table_body(t.body)
      if t.on_filegroup is Some(f) {
        self.s(" (on " + ident_text(f) + ")")
      }
      self.options_kv(t.options)
      self.close()
    }
    EnableTrigger(enable~, names, table) => {
      self.s(if enable { "(enable-trigger" } else { "(disable-trigger" })
      if names.is_empty() {
        self.atom("all")
      }
      for n in names {
        self.atom(n.name)
      }
      match table {
        Some(t) => self.s(" " + t.to_sexp())
        None => self.atom("database")
      }
      self.close()
    }
    AlterTable(n, action) => {
      self.s("(alter-table " + n.to_sexp() + " ")
      match action {
        Add(body, with_check~) => {
          self.s("(add")
          match with_check {
            Some(true) => self.atom("with-check")
            Some(false) => self.atom("with-nocheck")
            None => ()
          }
          self.table_body(body)
          self.close()
        }
        AlterColumn(c, ty, collate~, nullable~, ..) => {
          self.s("(alter-column " + ident_text(c) + " " + ty.to_sexp())
          if collate is Some(x) {
            self.s(" (collate " + x.name + ")")
          }
          match nullable {
            Some(true) => self.atom("null")
            Some(false) => self.atom("not-null")
            None => ()
          }
          self.close()
        }
        DropItems(items) => {
          self.s("(drop")
          for it in items {
            let (col, ife, name) = it
            self.s(
              " (" +
              (if col { "column" } else { "constraint" }) +
              (if ife { " if-exists" } else { "" }) +
              " " +
              ident_text(name) +
              ")",
            )
          }
          self.close()
        }
        CheckConstraints(enable~, names, with_check~) => {
          self.s(
            if enable {
              "(check-constraint"
            } else {
              "(nocheck-constraint"
            },
          )
          match with_check {
            Some(true) => self.atom("with-check")
            Some(false) => self.atom("with-nocheck")
            None => ()
          }
          if names.length() == 0 {
            self.atom("all")
          } else {
            for x in names {
              self.atom(ident_text(x))
            }
          }
          self.close()
        }
        EnableTriggers(enable~, names) => {
          self.s(if enable { "(enable-trigger" } else { "(disable-trigger" })
          if names.length() == 0 {
            self.atom("all")
          } else {
            for x in names {
              self.atom(ident_text(x))
            }
          }
          self.close()
        }
        SetOptions(opts) => {
          self.s("(set")
          self.options_kv(opts)
          self.close()
        }
      }
      self.close()
    }
    CreateIndex(ix) => {
      self.s("(create-index")
      if ix.unique {
        self.atom("unique")
      }
      self.s(clustered_text(ix.clustered))
      if ix.columnstore {
        self.atom("columnstore")
      }
      self.atom(ident_text(ix.name))
      self.atom(ix.table.to_sexp())
      if ix.columns.length() > 0 {
        self.sp()
        self.index_cols(ix.columns)
      }
      if ix.included.length() > 0 {
        self.s(" (include ")
        self.idents(ix.included)
        self.close()
      }
      self.where_(ix.where_)
      self.options_kv(ix.options)
      self.close()
    }
    DropIndex(if_exists~, items) => {
      self.s("(drop-index")
      if if_exists {
        self.atom("if-exists")
      }
      for it in items {
        match it.1 {
          Some(t) => self.s(" (" + it.0.to_sexp() + " " + t.to_sexp() + ")")
          None => self.atom(it.0.to_sexp())
        }
        if it.2 {
          self.atom("with-options")
        }
      }
      self.close()
    }
    AlterIndex(index~, table~, action~, options~) => {
      self.s("(alter-index ")
      self.s(
        match index {
          Some(i) => i.name
          None => "ALL"
        },
      )
      self.atom(table.to_sexp())
      self.atom(action)
      self.options_kv(options)
      self.close()
    }
    CreateView(v) => {
      self.s("(" + mode_text(v.mode) + "-view " + v.name.to_sexp())
      if v.columns.length() > 0 {
        self.sp()
        self.idents(v.columns)
      }
      self.strs("with", v.attributes)
      self.sp()
      self.query(v.query)
      if v.check_option {
        self.atom("check-option")
      }
      self.close()
    }
    CreateProcedure(p) => {
      self.s("(" + mode_text(p.mode) + "-procedure " + p.name.to_sexp())
      self.params(p.params)
      self.strs("with", p.options)
      self.stmts(p.body)
      self.close()
    }
    CreateFunction(f) => {
      self.s("(" + mode_text(f.mode) + "-function " + f.name.to_sexp())
      self.params(f.params)
      self.strs("with", f.options)
      match f.returns {
        Scalar(ty, body) => {
          self.s(" (returns " + ty.to_sexp() + ")")
          self.stmts(body)
        }
        InlineTable(q) => {
          self.s(" (returns-table ")
          self.query(q)
          self.close()
        }
        TableVariable(v, body, stmts) => {
          self.s(" (returns " + v + " (table")
          self.table_body(body)
          self.s("))")
          self.stmts(stmts)
        }
      }
      self.close()
    }
    CreateTrigger(t) => {
      self.s(
        "(" +
        mode_text(t.mode) +
        "-trigger " +
        t.name.to_sexp() +
        " (on " +
        t.table.to_sexp() +
        ")",
      )
      self.atom(
        match t.timing {
          After => "after"
          For => "for"
          InsteadOf => "instead-of"
        },
      )
      self.s(" (")
      for i, e in t.events {
        if i > 0 {
          self.sp()
        }
        self.s(
          match e {
            OnInsert => "insert"
            OnUpdate => "update"
            OnDelete => "delete"
          },
        )
      }
      self.close()
      self.strs("with", t.options)
      if t.not_for_replication {
        self.atom("not-for-replication")
      }
      self.stmts(t.body)
      self.close()
    }
    AlterSchemaTransfer(s, cls, n) =>
      self.s(
        "(alter-schema-transfer " +
        ident_text(s) +
        " " +
        cls +
        " " +
        n.to_sexp() +
        ")",
      )
    CreateSchema(n, authorization~) => {
      self.s("(create-schema " + ident_text(n))
      if authorization is Some(a) {
        self.s(" (authorization " + ident_text(a) + ")")
      }
      self.close()
    }
    CreateType(t) => {
      self.s("(create-type " + t.name.to_sexp())
      if t.base is Some(b) {
        self.s(" (from " + b.to_sexp() + ")")
      }
      match t.nullable {
        Some(true) => self.atom("null")
        Some(false) => self.atom("not-null")
        None => ()
      }
      if t.table is Some(b) {
        self.s(" (table")
        self.table_body(b)
        self.close()
      }
      self.close()
    }
    InsertBulk(n, cols, options) => {
      self.s("(insert-bulk " + n.to_sexp())
      for c in cols {
        self.s(" (" + c.0.name + " " + c.1.to_sexp() + ")")
      }
      for o in options {
        self.atom(quote(o))
      }
      self.close()
    }
    AlterSequence(n, options) => {
      self.s("(alter-sequence " + n.to_sexp())
      for o in options {
        self.atom(quote(o))
      }
      self.close()
    }
    CreateSynonym(n, base) => {
      self.s("(create-synonym " + n.to_sexp() + " " + base.to_sexp())
      self.close()
    }
    CreateSequence(n, type_~, options~) => {
      self.s("(create-sequence " + n.to_sexp())
      if type_ is Some(t) {
        self.s(" (as " + t.to_sexp() + ")")
      }
      for o in options {
        self.atom(quote(o))
      }
      self.close()
    }
    Drop(kind, if_exists~, names) => {
      self.s(
        "(drop-" +
        (match kind {
          DropTable => "table"
          DropView => "view"
          DropProcedure => "procedure"
          DropFunction => "function"
          DropTrigger => "trigger"
          DropSchema => "schema"
          DropType => "type"
          DropSequence => "sequence"
          DropSynonym => "synonym"
          DropDatabase => "database"
        }),
      )
      if if_exists {
        self.atom("if-exists")
      }
      for n in names {
        self.atom(n.to_sexp())
      }
      self.close()
    }
    Permission(p) => {
      self.open(
        match p.action {
          Grant => "grant"
          Deny => "deny"
          Revoke => "revoke"
        },
      )
      for x in p.permissions {
        self.atom(quote(x))
      }
      if p.on is Some(o) {
        self.s(" (on ")
        if p.on_class is Some(c) {
          self.s(c + "::")
        }
        self.s(o.to_sexp())
        self.close()
      }
      self.s(" (to")
      for x in p.principals {
        self.atom(ident_text(x))
      }
      self.close()
      if p.grant_option {
        self.atom("with-grant-option")
      }
      if p.cascade {
        self.atom("cascade")
      }
      self.close()
    }
    Declare(vars) => {
      self.open("declare")
      for v in vars {
        self.s(" (" + v.name + " " + v.type_.to_sexp())
        if v.init is Some(e) {
          self.sp()
          self.expr(e)
        }
        self.close()
      }
      self.close()
    }
    DeclareTable(name, body) => {
      self.s("(declare-table " + name)
      self.table_body(body)
      self.close()
    }
    DeclareCursor(c) | SetCursor(c) => {
      self.s(
        (if s.kind is SetCursor(_) {
          "(set-cursor "
        } else {
          "(declare-cursor "
        }) +
        ident_text(c.name),
      )
      for o in c.options {
        self.atom(quote(o))
      }
      self.sp()
      self.query(c.query)
      if c.for_update {
        self.s(" (for-update")
        for x in c.update_columns {
          self.atom(ident_text(x))
        }
        self.close()
      }
      self.close()
    }
    SetVar(v, op, e) => {
      self.s("(set " + v + " " + assign_text(op) + " ")
      self.expr(e)
      self.close()
    }
    SetVarMethod(v, m, args) => {
      self.s("(set-method " + v + " " + ident_text(m))
      for a in args {
        self.sp()
        self.expr(a)
      }
      self.close()
    }
    SetOption(opts, v) => {
      self.s("(set-option (" + opts.join(" ") + ") ")
      match v {
        On => self.s("ON")
        Off => self.s("OFF")
        Word(w) => self.s(w)
        ValueExpr(e) => self.expr(e)
      }
      self.close()
    }
    SetIdentityInsert(n, on) =>
      self.s(
        "(set-identity-insert " +
        n.to_sexp() +
        (if on { " ON" } else { " OFF" }) +
        ")",
      )
    SetIsolation(level) => self.s("(set-isolation " + quote(level) + ")")
    If(c, t, e) => {
      self.s("(if ")
      self.expr(c)
      self.sp()
      self.stmt(t)
      if e is Some(e) {
        self.s(" (else ")
        self.stmt(e)
        self.close()
      }
      self.close()
    }
    While(c, b) => {
      self.s("(while ")
      self.expr(c)
      self.sp()
      self.stmt(b)
      self.close()
    }
    Block(ss) => {
      self.open("block")
      self.stmts(ss)
      self.close()
    }
    TryCatch(t, c) => {
      self.s("(try")
      self.stmts(t)
      self.s(" (catch")
      self.stmts(c)
      self.s("))")
    }
    Break => self.s("(break)")
    Continue => self.s("(continue)")
    Return(e) => self.opt_expr("return", e)
    Goto(l) => self.s("(goto " + ident_text(l) + ")")
    Label(l) => self.s("(label " + ident_text(l) + ")")
    WaitFor(kind, e) => {
      self.s("(waitfor " + kind + " ")
      self.expr(e)
      self.close()
    }
    Backup(log~, database~, devices~, options~) => {
      self.s(if log { "(backup log " } else { "(backup database " })
      self.expr(database)
      self.backup_parts(devices, options)
      self.close()
    }
    Restore(kind~, database~, devices~, options~) => {
      self.s("(restore " + kind)
      match database {
        Some(d) => {
          self.s(" ")
          self.expr(d)
        }
        None => ()
      }
      self.backup_parts(devices, options)
      self.close()
    }
    Dbcc(name, args, options) => {
      self.s("(dbcc " + name)
      for a in args {
        self.sp()
        self.expr(a)
      }
      for o in options {
        self.s(" " + o)
      }
      self.close()
    }
    Throw(args) => {
      self.open("throw")
      for a in args {
        self.sp()
        self.expr(a)
      }
      self.close()
    }
    RaisError(args, options~) => {
      self.open("raiserror")
      for a in args {
        self.sp()
        self.expr(a)
      }
      for o in options {
        self.atom(o)
      }
      self.close()
    }
    Print(e) => {
      self.s("(print ")
      self.expr(e)
      self.close()
    }
    Exec(e) => self.exec(e)
    ExecString(parts) => {
      self.open("exec-string")
      for p in parts {
        self.sp()
        self.expr(p)
      }
      self.close()
    }
    BeginTran(name~, distributed~) =>
      self.opt_expr(
        if distributed {
          "begin-distributed-tran"
        } else {
          "begin-tran"
        },
        name,
      )
    Commit(name~) => self.opt_expr("commit", name)
    Rollback(name~) => self.opt_expr("rollback", name)
    Save(name~) => self.opt_expr("save", name)
    OpenCursor(c, global~) =>
      self.s(
        "(open " + (if global { "global " } else { "" }) + ident_text(c) + ")",
      )
    CloseCursor(c, global~) =>
      self.s(
        "(close " + (if global { "global " } else { "" }) + ident_text(c) + ")",
      )
    Deallocate(c, global~) =>
      self.s(
        "(deallocate " +
        (if global { "global " } else { "" }) +
        ident_text(c) +
        ")",
      )
    Fetch(f) => {
      self.s("(fetch ")
      match f.orientation {
        Next => self.s("next")
        Prior => self.s("prior")
        First => self.s("first")
        Last => self.s("last")
        Absolute(e) => {
          self.s("(absolute ")
          self.expr(e)
          self.close()
        }
        Relative(e) => {
          self.s("(relative ")
          self.expr(e)
          self.close()
        }
      }
      self.atom((if f.global { "global " } else { "" }) + ident_text(f.cursor))
      if f.into.length() > 0 {
        self.s(" (into " + f.into.join(" ") + ")")
      }
      self.close()
    }
    Use(db) => self.s("(use " + ident_text(db) + ")")
    CreateDatabase(db, ..) => self.s("(create-database " + ident_text(db) + ")")
    AlterDatabase(target~, action) => {
      let t = match target {
        Some(db) => ident_text(db)
        None => "current"
      }
      let a = match action {
        Collate(c) => "(collate " + ident_text(c) + ")"
        SetOptions(opts) =>
          "(set" +
          opts
          .map(o => {
            match o.value {
              Some(v) => " (" + o.name + " " + v + ")"
              None => " " + o.name
            }
          })
          .join("") +
          ")"
        PreviewFeatures(v) => "(preview-features " + v.to_string() + ")"
        OtherAction(w) => "(other " + w + ")"
      }
      self.s("(alter-database " + t + " " + a + ")")
    }
  }
}

///|
fn W::backup_parts(
  self : W,
  devices : Array[BackupDevice],
  options : Array[BackupOption],
) -> Unit {
  for d in devices {
    self.s(" (device " + d.kind + " ")
    self.expr(d.value)
    self.close()
  }
  for o in options {
    self.s(" (" + o.name)
    match o.value {
      Some(v) => {
        self.s(" ")
        self.expr(v)
      }
      None => ()
    }
    match o.move_to {
      Some(v) => {
        self.s(" to ")
        self.expr(v)
      }
      None => ()
    }
    if o.args {
      self.s(" (...)")
    }
    self.close()
  }
}
