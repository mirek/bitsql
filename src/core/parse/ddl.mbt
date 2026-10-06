///|
/// `ON filegroup` after a table / index / constraint.
fn Parser::on_filegroup(self : Parser) -> @ast.Ident? raise @ast.SyntaxError {
  if self.is_kw("ON") {
    self.pos += 1
    let fg = self.any_ident()
    if self.is_punct("(") {
      // Partition scheme column: ON ps(col)
      ignore(self.paren_idents())
    }
    Some(fg)
  } else {
    None
  }
}

///|
/// `WITH ( name = value, ... )` or legacy `WITH FILLFACTOR = n`.
fn Parser::with_options(
  self : Parser,
  json_index? : Bool = false,
  alter_index? : Bool = false,
) -> Array[@ast.OptionKV] raise @ast.SyntaxError {
  let out = []
  if !self.is_kw("WITH") {
    return out
  }
  if self.is_punct_at(1, "(") {
    self.pos += 2
    while true {
      if json_index &&
        self.is_kw("OPTIMIZE_FOR_ARRAY_SEARCH") &&
        self.is_punct_at(1, "=") &&
        !self.is_kw_at(2, "ON") &&
        !self.is_kw_at(2, "OFF") {
        self.pos += 2
        raise self.error()
      }
      if alter_index {
        self.check_alter_index_option()
      }
      out.push(self.option_kv())
      if !self.eat_punct(",") {
        break
      }
    }
    self.expect_punct(")")
  } else if self.is_kw_at(1, "FILLFACTOR") {
    self.pos += 1
    out.push(self.option_kv())
  }
  out
}

///|
/// `ALTER INDEX { name | ALL } ON table action` (after ALTER INDEX).
/// REBUILD/REORGANIZE take `WITH (...)`, SET takes `(...)`; partition
/// clauses are not parsed.
fn Parser::alter_index(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  let index = if self.eat_kw("ALL") { None } else { Some(self.ident()) }
  self.expect_kw("ON")
  let table = self.object_name()
  let t = self.peek()
  let action = upper(t)
  let options = match action {
    "DISABLE" => {
      self.pos += 1
      []
    }
    "REBUILD" | "REORGANIZE" => {
      self.pos += 1
      self.with_options(alter_index=true)
    }
    "SET" => {
      self.pos += 1
      self.expect_punct("(")
      let out = []
      while true {
        self.check_alter_index_option()
        out.push(self.option_kv())
        if !self.eat_punct(",") {
          break
        }
      }
      self.expect_punct(")")
      out
    }
    _ => raise self.error()
  }
  AlterIndex(index~, table~, action~, options~)
}

///|
fn Parser::check_alter_index_option(
  self : Parser,
) -> Unit raise @ast.SyntaxError {
  if self.is_kw("OPTIMIZE_FOR_ARRAY_SEARCH") {
    raise @ast.SyntaxError(
      number=155,
      severity=15,
      state=1,
      message="'OPTIMIZE_FOR_ARRAY_SEARCH' is not a recognized ALTER INDEX option.",
      span=self.peek().span,
    )
  }
}

///|
fn Parser::option_kv(self : Parser) -> @ast.OptionKV raise @ast.SyntaxError {
  let name = upper(self.any_ident_tok())
  if self.eat_punct("=") {
    let t = self.peek()
    let value = match t.kind {
      Word | QuotedIdent | IntNum | DecimalNum | Str | NStr => {
        self.pos += 1
        t.text
      }
      _ => raise self.error()
    }
    // e.g. DATA_COMPRESSION = PAGE ON PARTITIONS (1 TO 2)
    let value = if self.is_kw("ON") && self.is_kw_at(1, "PARTITIONS") {
      self.pos += 2
      self.expect_punct("(")
      let txt = self.balanced_text()
      self.expect_punct(")")
      value + " ON PARTITIONS (" + txt + ")"
    } else {
      value
    }
    { name, value: Some(value), }
  } else {
    { name, value: None, }
  }
}

///|
fn Parser::any_ident_tok(self : Parser) -> @lex.Token raise @ast.SyntaxError {
  let t = self.peek()
  if t.kind is Word || t.kind is QuotedIdent {
    self.pos += 1
    t
  } else {
    raise self.error()
  }
}

///|
fn Parser::clustered(self : Parser) -> Bool? {
  if self.eat_kw("CLUSTERED") {
    Some(true)
  } else if self.eat_kw("NONCLUSTERED") {
    Some(false)
  } else {
    None
  }
}

///|
fn Parser::index_columns(
  self : Parser,
) -> Array[@ast.IndexColumn] raise @ast.SyntaxError {
  self.expect_punct("(")
  let out : Array[@ast.IndexColumn] = []
  while true {
    let name = self.ident()
    let desc = if self.eat_kw("DESC") {
      true
    } else {
      ignore(self.eat_kw("ASC"))
      false
    }
    out.push({ name, desc, })
    if !self.eat_punct(",") {
      break
    }
  }
  self.expect_punct(")")
  out
}

///|
fn Parser::ref_action(self : Parser) -> @ast.RefAction raise @ast.SyntaxError {
  if self.eat_kw("CASCADE") {
    Cascade
  } else if self.is_kw("NO") {
    self.pos += 1
    self.expect_kw("ACTION")
    NoAction
  } else {
    self.expect_kw("SET")
    if self.eat_kw("NULL") {
      SetNull
    } else {
      self.expect_kw("DEFAULT")
      SetDefault
    }
  }
}

///|
/// After `REFERENCES`.
fn Parser::foreign_ref(self : Parser) -> @ast.ForeignRef raise @ast.SyntaxError {
  let table = self.object_name()
  let columns = if self.is_punct("(") { self.paren_idents() } else { [] }
  let mut on_delete = None
  let mut on_update = None
  let mut not_for_replication = false
  while true {
    if self.is_kw("ON") && self.is_kw_at(1, "DELETE") && on_delete is None {
      self.pos += 2
      on_delete = Some(self.ref_action())
    } else if self.is_kw("ON") &&
      self.is_kw_at(1, "UPDATE") &&
      on_update is None {
      self.pos += 2
      on_update = Some(self.ref_action())
    } else if self.is_kw("NOT") && self.is_kw_at(1, "FOR") {
      self.pos += 2
      self.expect_kw("REPLICATION")
      not_for_replication = true
    } else {
      break
    }
  }
  { table, columns, on_delete, on_update, not_for_replication, }
}

///|
fn Parser::not_for_replication(self : Parser) -> Bool raise @ast.SyntaxError {
  if self.is_kw("NOT") && self.is_kw_at(1, "FOR") {
    self.pos += 2
    self.expect_kw("REPLICATION")
    true
  } else {
    false
  }
}

///|
/// Signed numeric literal as raw text (IDENTITY seed/increment).
fn Parser::signed_number(self : Parser) -> String raise @ast.SyntaxError {
  let sign = if self.eat_punct("-") {
    "-"
  } else {
    ignore(self.eat_punct("+"))
    ""
  }
  let t = self.peek()
  if t.kind is IntNum || t.kind is DecimalNum {
    self.pos += 1
    sign + t.text
  } else {
    raise self.error()
  }
}

///|
fn Parser::at_constraint_start(self : Parser) -> Bool {
  self.is_kw("CONSTRAINT") ||
  self.is_kw("PRIMARY") ||
  self.is_kw("UNIQUE") ||
  self.is_kw("FOREIGN") ||
  self.is_kw("CHECK") ||
  self.is_kw("DEFAULT")
}

///|
/// Column or table-level element list inside `( ... )` (or bare, for ALTER
/// TABLE ADD), appended to `body`. `trailing_comma`: one `,` may end the
/// list, as CREATE TABLE allows (captured: catalog/create-table-trailing-comma;
/// table variables, table types, TVF return tables and ALTER TABLE ADD do
/// not).
fn Parser::table_elements(
  self : Parser,
  body : @ast.TableBody,
  trailing_comma? : Bool = false,
) -> Unit raise @ast.SyntaxError {
  while true {
    if self.at_constraint_start() {
      body.constraints.push(self.table_constraint())
    } else if self.is_kw("INDEX") {
      self.pos += 1
      let name = self.ident()
      let unique = self.eat_kw("UNIQUE")
      let clustered = self.clustered()
      let columns = self.index_columns()
      let included = if self.eat_kw("INCLUDE") {
        self.paren_idents()
      } else {
        []
      }
      let where_ = if self.eat_kw("WHERE") { Some(self.cond()) } else { None }
      let options = self.with_options()
      ignore(self.on_filegroup())
      body.indexes.push({
        name,
        unique,
        clustered,
        columns,
        included,
        where_,
        options,
      })
    } else {
      body.columns.push(self.column_def(body.constraints))
    }
    if !self.eat_punct(",") || (trailing_comma && self.is_punct(")")) {
      break
    }
  }
}

///|
fn Parser::table_body(
  self : Parser,
  trailing_comma? : Bool = false,
) -> @ast.TableBody raise @ast.SyntaxError {
  self.expect_punct("(")
  let body : @ast.TableBody = { columns: [], constraints: [], indexes: [], }
  self.table_elements(body, trailing_comma~)
  self.expect_punct(")")
  body
}

///|
fn Parser::table_constraint(
  self : Parser,
) -> @ast.TableConstraint raise @ast.SyntaxError {
  let start = self.start()
  if self.table_variable && self.is_kw("CONSTRAINT") {
    raise near(self.peek())
  }
  let name = if self.eat_kw("CONSTRAINT") { Some(self.ident()) } else { None }
  let kind : @ast.TableConstraintKind = if self.is_kw("PRIMARY") {
    self.pos += 1
    self.expect_kw("KEY")
    let clustered = self.clustered()
    let cols = self.index_columns()
    let options = self.with_options()
    ignore(self.on_filegroup())
    PrimaryKey(clustered~, cols, options~)
  } else if self.eat_kw("UNIQUE") {
    let clustered = self.clustered()
    let cols = self.index_columns()
    let options = self.with_options()
    ignore(self.on_filegroup())
    Unique(clustered~, cols, options~)
  } else if self.is_kw("FOREIGN") {
    self.pos += 1
    self.expect_kw("KEY")
    let cols = self.paren_idents()
    self.expect_kw("REFERENCES")
    ForeignKey(cols, self.foreign_ref())
  } else if self.eat_kw("CHECK") {
    let nfr = self.not_for_replication()
    self.expect_punct("(")
    let e = self.cond()
    self.expect_punct(")")
    Check(e, not_for_replication=nfr)
  } else if self.eat_kw("DEFAULT") {
    let e = self.scalar()
    self.expect_kw("FOR")
    let col = self.ident()
    ignore(self.with_values())
    DefaultFor(e, col)
  } else {
    raise self.error()
  }
  { name, kind, span: self.span_from(start), column_level: false, }
}

///|
fn Parser::with_values(self : Parser) -> Bool {
  if self.is_kw("WITH") && self.is_kw_at(1, "VALUES") {
    self.pos += 2
    true
  } else {
    false
  }
}

///|
/// A column-level PRIMARY KEY / UNIQUE with a column list
/// (`b int CONSTRAINT pk PRIMARY KEY (a, b)`) is a table-level constraint:
/// it goes to `table_constraints` (captured: msduck gaps-keys
/// column-level-list).
fn Parser::column_def(
  self : Parser,
  table_constraints : Array[@ast.TableConstraint],
) -> @ast.ColumnDef raise @ast.SyntaxError {
  let start = self.start()
  let name = self.ident()
  let mut type_ = None
  let mut computed = None
  let mut persisted = false
  if self.eat_kw("AS") {
    computed = Some(self.scalar())
    if self.eat_kw("PERSISTED") {
      persisted = true
    }
  } else if name.name.to_lower() == "timestamp" &&
    (self.is_punct(",") || self.is_punct(")")) {
    // captured: a column named timestamp without a type is a timestamp
    // column (msduck gaps-rowversion_identity #036)
    type_ = Some(@ast.TypeName::{
      schema: None,
      name: "timestamp",
      args: [],
      span: name.span,
    })
  } else {
    type_ = Some(self.type_name())
  }
  let mut collate = None
  let mut nullable = None
  let mut identity = None
  let mut rowguidcol = false
  let mut sparse = false
  let constraints : Array[@ast.ColumnConstraint] = []
  while true {
    let cstart = self.start()
    if self.eat_kw("COLLATE") {
      collate = Some(self.any_ident())
    } else if self.eat_kw("NULL") {
      nullable = Some(true)
    } else if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
      self.pos += 2
      nullable = Some(false)
    } else if self.is_kw("NOT") && self.is_kw_at(1, "FOR") {
      ignore(self.not_for_replication())
    } else if self.eat_kw("IDENTITY") {
      if self.eat_punct("(") {
        let seed = self.signed_number()
        self.expect_punct(",")
        let inc = self.signed_number()
        self.expect_punct(")")
        identity = Some(@ast.Identity::{
          seed: Some(seed),
          increment: Some(inc),
        })
      } else {
        identity = Some(@ast.Identity::{ seed: None, increment: None, })
      }
    } else if self.eat_kw("ROWGUIDCOL") {
      rowguidcol = true
    } else if self.eat_kw("SPARSE") {
      sparse = true
    } else if self.is_kw("PERSISTED") && computed is Some(_) {
      self.pos += 1
      persisted = true
    } else if self.at_constraint_start() || self.is_kw("REFERENCES") {
      if self.table_variable && self.is_kw("CONSTRAINT") {
        raise near(self.peek())
      }
      let cname = if self.eat_kw("CONSTRAINT") {
        Some(self.ident())
      } else {
        None
      }
      let kind : @ast.ColumnConstraintKind = if self.eat_kw("DEFAULT") {
        let e = self.scalar()
        ignore(self.with_values())
        ColDefault(e)
      } else if self.is_kw("PRIMARY") {
        self.pos += 1
        self.expect_kw("KEY")
        let clustered = self.clustered()
        if self.is_punct("(") {
          let cols = self.index_columns()
          let options = self.with_options()
          ignore(self.on_filegroup())
          table_constraints.push({
            name: cname,
            kind: PrimaryKey(clustered~, cols, options~),
            span: self.span_from(cstart),
            column_level: true,
          })
          continue
        }
        let options = self.with_options()
        ignore(self.on_filegroup())
        ColPrimaryKey(clustered~, options~)
      } else if self.eat_kw("UNIQUE") {
        let clustered = self.clustered()
        if self.is_punct("(") {
          let cols = self.index_columns()
          let options = self.with_options()
          ignore(self.on_filegroup())
          table_constraints.push({
            name: cname,
            kind: Unique(clustered~, cols, options~),
            span: self.span_from(cstart),
            column_level: true,
          })
          continue
        }
        let options = self.with_options()
        ignore(self.on_filegroup())
        ColUnique(clustered~, options~)
      } else if self.eat_kw("CHECK") {
        let nfr = self.not_for_replication()
        self.expect_punct("(")
        let e = self.cond()
        self.expect_punct(")")
        ColCheck(e, not_for_replication=nfr)
      } else {
        if self.is_kw("FOREIGN") {
          self.pos += 1
          self.expect_kw("KEY")
          // with its own column list it names the referencing column(s)
          // (captured: constraints/inline-fk-columns)
          if self.is_punct("(") {
            let cols = self.paren_idents()
            self.expect_kw("REFERENCES")
            let r = self.foreign_ref()
            table_constraints.push({
              name: cname,
              kind: ForeignKey(cols, r),
              span: self.span_from(cstart),
              column_level: true,
            })
            continue
          }
        }
        self.expect_kw("REFERENCES")
        ColReferences(self.foreign_ref())
      }
      constraints.push({ name: cname, kind, span: self.span_from(cstart), })
    } else {
      break
    }
  }
  {
    name,
    type_,
    computed,
    persisted,
    collate,
    nullable,
    identity,
    rowguidcol,
    sparse,
    constraints,
    span: self.span_from(start),
  }
}

///|
fn Parser::create_table(
  self : Parser,
) -> @ast.CreateTable raise @ast.SyntaxError {
  let name = self.object_name()
  let body = self.table_body(trailing_comma=true)
  let mut on_filegroup = self.on_filegroup()
  if self.eat_kw("TEXTIMAGE_ON") {
    ignore(self.any_ident())
  }
  let options = self.with_options()
  if on_filegroup is None {
    on_filegroup = self.on_filegroup()
  }
  { name, body, on_filegroup, options, }
}

///|
fn Parser::alter_table(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  let name = self.object_name()
  let with_check : Bool? = if self.is_kw("WITH") && self.is_kw_at(1, "CHECK") {
    self.pos += 2
    Some(true)
  } else if self.is_kw("WITH") && self.is_kw_at(1, "NOCHECK") {
    self.pos += 2
    Some(false)
  } else {
    None
  }
  let action : @ast.AlterTableAction = if self.eat_kw("ADD") {
    let body : @ast.TableBody = { columns: [], constraints: [], indexes: [], }
    self.table_elements(body)
    Add(body, with_check~)
  } else if (self.is_kw("CHECK") || self.is_kw("NOCHECK")) &&
    self.is_kw_at(1, "CONSTRAINT") {
    let enable = self.is_kw("CHECK")
    self.pos += 2
    let names = if self.eat_kw("ALL") {
      []
    } else {
      let ns = [self.ident()]
      while self.eat_punct(",") {
        ns.push(self.ident())
      }
      ns
    }
    CheckConstraints(enable~, names, with_check~)
  } else if with_check is Some(_) {
    raise self.error()
  } else if self.is_kw("ALTER") && self.is_kw_at(1, "COLUMN") {
    self.pos += 2
    let col = self.ident()
    let ty = self.type_name()
    let mut collate = None
    let mut nullable = None
    let options = []
    while true {
      if self.eat_kw("COLLATE") {
        collate = Some(self.any_ident())
      } else if self.eat_kw("NULL") {
        nullable = Some(true)
      } else if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
        self.pos += 2
        nullable = Some(false)
      } else if self.eat_kw("SPARSE") {
        options.push("SPARSE")
      } else {
        break
      }
    }
    if self.is_kw("WITH") && self.is_punct_at(1, "(") {
      for o in self.with_options() {
        options.push(o.name)
      }
    }
    AlterColumn(col, ty, collate~, nullable~, options~)
  } else if self.eat_kw("DROP") {
    let items = []
    let mut is_column = false
    while true {
      if self.eat_kw("COLUMN") {
        is_column = true
      } else if self.eat_kw("CONSTRAINT") {
        is_column = false
      }
      let if_exists = if self.is_kw("IF") && self.is_kw_at(1, "EXISTS") {
        self.pos += 2
        true
      } else {
        false
      }
      items.push((is_column, if_exists, self.ident()))
      if !self.eat_punct(",") {
        break
      }
    }
    DropItems(items)
  } else if self.is_kw("ENABLE") || self.is_kw("DISABLE") {
    let enable = self.is_kw("ENABLE")
    self.pos += 1
    self.expect_kw("TRIGGER")
    let names = if self.eat_kw("ALL") {
      []
    } else {
      let ns = [self.ident()]
      while self.eat_punct(",") {
        ns.push(self.ident())
      }
      ns
    }
    EnableTriggers(enable~, names)
  } else if self.is_kw("SET") && self.is_punct_at(1, "(") {
    self.pos += 2
    let opts = [self.option_kv()]
    while self.eat_punct(",") {
      opts.push(self.option_kv())
    }
    self.expect_punct(")")
    SetOptions(opts)
  } else {
    raise self.error()
  }
  AlterTable(name, action)
}

///|
/// After `CREATE`, at `[UNIQUE] [CLUSTERED|NONCLUSTERED] [COLUMNSTORE] INDEX`.
fn Parser::create_index(
  self : Parser,
) -> @ast.CreateIndex raise @ast.SyntaxError {
  let json = self.eat_kw("JSON")
  let vector = !json && self.eat_kw("VECTOR")
  let unique = !json && !vector && self.eat_kw("UNIQUE")
  let clustered = if json || vector { None } else { self.clustered() }
  let columnstore = !json && !vector && self.eat_kw("COLUMNSTORE")
  self.expect_kw("INDEX")
  let name = self.ident()
  self.expect_kw("ON")
  let table = self.object_name()
  let columns : Array[@ast.IndexColumn] = if json || vector {
    self.expect_punct("(")
    let name = self.ident()
    self.expect_punct(")")
    [{ name, desc: false, }]
  } else if self.is_punct("(") {
    self.index_columns()
  } else {
    []
  }
  let json_paths = if json {
    let paths = []
    if self.eat_kw("FOR") {
      self.expect_punct("(")
      while true {
        let token = self.peek()
        if !(token.kind is (Str | NStr)) {
          raise self.error()
        }
        self.pos += 1
        paths.push(token.text)
        if !self.eat_punct(",") {
          break
        }
      }
      self.expect_punct(")")
    } else {
      paths.push("$")
    }
    Some(paths)
  } else {
    None
  }
  if (json || vector) && (self.is_kw("INCLUDE") || self.is_kw("WHERE")) {
    raise self.error()
  }
  let included = if self.eat_kw("INCLUDE") { self.paren_idents() } else { [] }
  let where_ = if self.eat_kw("WHERE") { Some(self.cond()) } else { None }
  let options = if vector {
    self.vector_index_options()
  } else {
    self.with_options(json_index=json)
  }
  if json && self.is_kw("ON") {
    raise self.error()
  }
  let on_filegroup = self.on_filegroup()
  {
    unique,
    clustered,
    columnstore,
    json_paths,
    vector,
    name,
    table,
    columns,
    included,
    where_,
    options,
    on_filegroup,
  }
}

///|
fn Parser::if_exists(self : Parser) -> Bool {
  if self.is_kw("IF") && self.is_kw_at(1, "EXISTS") {
    self.pos += 2
    true
  } else {
    false
  }
}

///|
fn Parser::drop_stmt(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  self.expect_kw("DROP")
  if self.eat_kw("INDEX") {
    let if_exists = self.if_exists()
    let items = []
    while true {
      let ix = self.object_name()
      let table = if self.eat_kw("ON") {
        if ix.parts.length() != 1 {
          raise near(self.toks[self.pos - 1])
        }
        Some(self.object_name())
      } else {
        if ix.parts.length() < 2 {
          // captured: msduck-runs drop-index #020
          raise @ast.SyntaxError(
            number=159,
            severity=15,
            state=1,
            message="Must specify the table name and index name for the DROP INDEX statement.",
            span=ix.span,
          )
        }
        None
      }
      // drop options (MAXDOP, MOVE TO ...) apply to clustered indexes only
      // (captured: msduck gaps-keys clustered-conflicts-8,
      // constraints/index-options 3748); ONLINE = OFF is accepted
      // (msduck-runs drop-index #023)
      let options = table is Some(_) &&
        self
        .with_options()
        .iter()
        .any(o => {
          !(o.name == "ONLINE" && o.value.map(v => v.to_upper()) == Some("OFF"))
        })
      items.push((ix, table, options))
      if !self.eat_punct(",") {
        break
      }
    }
    return DropIndex(if_exists~, items)
  }
  let t = self.peek()
  let kind : @ast.DropKind = match upper(t) {
    "TABLE" => DropTable
    "VIEW" => DropView
    "PROC" | "PROCEDURE" => DropProcedure
    "FUNCTION" => DropFunction
    "TRIGGER" => DropTrigger
    "SCHEMA" => DropSchema
    "TYPE" => DropType
    "SEQUENCE" => DropSequence
    "SYNONYM" => DropSynonym
    "DATABASE" => DropDatabase
    _ => raise self.error()
  }
  self.pos += 1
  let if_exists = self.if_exists()
  let names = [self.object_name()]
  while self.eat_punct(",") {
    names.push(self.object_name())
  }
  Drop(kind, if_exists~, names)
}

///|
/// Procedure / function parameter list (optionally parenthesised for procs).
fn Parser::params(
  self : Parser,
  parens : Bool,
) -> Array[@ast.Param] raise @ast.SyntaxError {
  let out = []
  let has_paren = if parens { true } else { self.eat_punct("(") }
  if parens {
    self.expect_punct("(")
  }
  if self.peek().kind is Variable {
    while true {
      out.push(self.param())
      if !self.eat_punct(",") {
        break
      }
    }
  }
  if has_paren {
    self.expect_punct(")")
  }
  out
}

///|
fn Parser::param(self : Parser) -> @ast.Param raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  if !(t.kind is Variable) {
    raise self.error()
  }
  self.pos += 1
  ignore(self.eat_kw("AS"))
  let type_ = self.type_name()
  let varying = self.eat_kw("VARYING")
  if self.is_kw("NULL") {
    self.pos += 1
  } else if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
    self.pos += 2
  }
  let default_ = if self.eat_punct("=") { Some(self.scalar()) } else { None }
  let mut output = false
  let mut read_only = false
  while true {
    if self.eat_kw("OUTPUT") || self.eat_kw("OUT") {
      output = true
    } else if self.eat_kw("READONLY") {
      // READONLY ends the declaration (captured: `READONLY OUTPUT` and
      // `READONLY = NULL` are 102)
      read_only = true
      break
    } else {
      break
    }
  }
  {
    name: t.text,
    type_,
    varying,
    default_,
    output,
    read_only,
    span: self.span_from(start),
  }
}

///|
/// Module `WITH` options up to `AS` / `FOR` / `RETURNS` etc.: upper-cased,
/// multi-word options joined (`EXECUTE AS OWNER`, `RETURNS NULL ON NULL INPUT`).
fn Parser::module_options(
  self : Parser,
) -> Array[String] raise @ast.SyntaxError {
  let out = []
  if !self.eat_kw("WITH") {
    return out
  }
  while true {
    let t = self.peek()
    if !(t.kind is Word) {
      raise self.error()
    }
    let u = upper(t)
    self.pos += 1
    let text = if u == "EXECUTE" || u == "EXEC" {
      self.expect_kw("AS")
      let who = self.peek()
      self.pos += 1
      "EXECUTE AS " +
      (match who.kind {
        Str | NStr => "'" + who.text + "'"
        Word => upper(who)
        _ => raise near(who)
      })
    } else if u == "RETURNS" {
      self.expect_kw("NULL")
      self.expect_kw("ON")
      self.expect_kw("NULL")
      self.expect_kw("INPUT")
      "RETURNS NULL ON NULL INPUT"
    } else if u == "CALLED" {
      self.expect_kw("ON")
      self.expect_kw("NULL")
      self.expect_kw("INPUT")
      "CALLED ON NULL INPUT"
    } else if self.eat_punct("=") {
      u + " = " + upper(self.advance())
    } else {
      u
    }
    out.push(text)
    if !self.eat_punct(",") {
      break
    }
  }
  out
}
