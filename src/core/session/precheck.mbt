///|
/// Batch-level compile checks: a variable must be declared earlier in the
/// batch text (or be a parameter). SQL Server rejects the whole batch with
/// error 137 before running anything.
fn precheck_batch(
  stmts : Array[@ast.Stmt],
  params : Map[String, @bind.VarInfo],
  in_proc? : Bool = false,
  before? : Array[(@types.SqlError, Int)] = [],
  set_column_name? : (@ast.TableRef, String) -> String = (_, n) => n,
) -> (@types.SqlError, Int)? {
  let declared : Set[String] = Set([])
  let temp_creates : Set[String] = Set([])
  // declared types, for RAISERROR substitution parameter checks
  let types : Map[String, @types.SqlType] = Map([])
  for k, v in params {
    declared.add(k)
    types[k] = v.ty
  }
  let mut failure : (@types.SqlError, Int)? = None
  fn check_name(name : String, line : Int) -> Unit {
    if failure is None && !declared.contains(name.to_lower()) {
      failure = Some(
        (
          @types.sql_error(
            137,
            "Must declare the scalar variable \"\{name}\".",
            state=2,
            severity=15,
          ),
          line,
        ),
      )
    }
  }

  fn expr(e : @ast.Expr, line : Int) -> Unit {
    walk_expr(e, fn(x) {
      match x.kind {
        Var(n) => check_name(n, x.span.line)
        // The native function advertises 3..4 but rejects four arguments;
        // nonempty calls outside that range emit both 174 and 189.
        // Captured: sql2025/vector-distance-{special,options,extremes}.
        Call(c) if failure is None &&
          c.name.parts.length() == 1 &&
          c.name.base().to_lower() == "vector_distance" &&
          c.args.length() != 3 => {
          let fixed = @types.sql_error(
            174,
            "The vector_distance function requires 3 argument(s).",
            state=6,
            severity=15,
          )
          let ranged = @types.sql_error(
            189,
            "The vector_distance function requires 3 to 4 arguments.",
            severity=15,
          )
          if c.args.length() == 4 {
            failure = Some((fixed, x.span.line))
          } else {
            if c.args.length() > 0 {
              before.push((fixed, x.span.line))
            }
            failure = Some((ranged, x.span.line))
          }
        }
        // captured: ranking and offset functions with the wrong number of
        // arguments are 4114 / 10755 (class 15) for the whole batch
        // (msduck-runs count-ranking-declarations#054, tail/window-arity)
        Call(c) if failure is None &&
          c.over is Some(_) &&
          window_arity_error(c.name.base(), c.args.length()) is Some(e) =>
          failure = Some((e, x.span.line))
        // captured: window-only functions without OVER are 10753 for the
        // whole batch, state 3 for ranking/distribution, 1 for offset and
        // value functions (msduck-runs distribution-reference#009,
        // tail/window-arity)
        Call(c) if failure is None &&
          c.over is None &&
          c.name.parts.length() == 1 &&
          window_over_state(c.name.base()) is Some(st) =>
          failure = Some(
            (
              @types.sql_error(
                10753,
                "The function '\{c.name.base()}' must have an OVER clause.",
                state=st,
                severity=15,
              ),
              x.span.line,
            ),
          )
        // captured: COUNT(NULL) / COUNT_BIG(NULL), also parenthesized,
        // DISTINCT or windowed, is 8117 for the whole batch (msduck
        // count-null-compilation)
        Call(c) if failure is None && !c.star && c.args.length() == 1 => {
          let fname = c.name.base().to_lower()
          if (fname == "count" || fname == "count_big") &&
            @bind.is_null_argument(c.args[0]) {
            failure = Some(
              (
                @types.sql_error(
                  8117,
                  "Operand data type NULL is invalid for \{fname} operator.",
                ),
                x.span.line,
              ),
            )
          }
        }
        // captured: a variable scale of DATETIME2FROMPARTS & co is 10760
        // for the whole batch (functions/date#614)
        Call(c) if failure is None &&
          (match c.name.base().to_upper() {
            "DATETIME2FROMPARTS" => c.args.length() == 8
            "TIMEFROMPARTS" => c.args.length() == 5
            "DATETIMEOFFSETFROMPARTS" => c.args.length() == 10
            _ => false
          }) &&
          c.args[c.args.length() - 1].kind is Var(_) => {
          let tname = match c.name.base().to_upper() {
            "DATETIME2FROMPARTS" => "datetime2"
            "TIMEFROMPARTS" => "time"
            _ => "datetimeoffset"
          }
          failure = Some(
            (
              @types.sql_error(
                10760,
                "Scale argument is not valid. Valid expressions for data type \{tname} scale argument are integer constants and integer constant expressions.",
              ),
              x.span.line,
            ),
          )
        }
        // captured: a style variable of a non-integer type is 8116 for the
        // whole batch (the DECLARE before it does not run)
        Convert(_, _, style=Some({ kind: Var(vn), .. }), ..) if failure is None =>
          match types.get(vn.to_lower()) {
            Some(t) if !(t.family() is FInteger) =>
              failure = Some(
                (
                  @types.sql_error(
                    8116,
                    "Argument data type \{t.base_name()} is invalid for argument 3 of convert function.",
                  ),
                  x.span.line,
                ),
              )
            _ => ()
          }
        _ => ()
      }
    })
    ignore(line)
  }

  fn stmt(s : @ast.Stmt) -> Unit {
    let line = s.span.line
    match s.kind {
      // captured (corpus database/cross-database-ddl): a database prefix on
      // CREATE VIEW / PROCEDURE, any database, is 166 for the whole batch,
      // reported on line 13 wherever the statement is
      CreateView({ name, .. }) | CreateProcedure({ name, .. }) if failure
        is None &&
        has_database_part(name) => {
        let what = if s.kind is CreateView(_) { "VIEW" } else { "PROCEDURE" }
        failure = Some(
          (
            @types.sql_error(
              166,
              "'CREATE/ALTER \{what}' does not allow specifying the database name as a prefix to the object name.",
              severity=15,
            ),
            13,
          ),
        )
      }
      Declare(vars) =>
        for v in vars {
          if v.init is Some(i) {
            expr(i, line)
          }
          // a procedure body is compiled at CREATE: redeclaring a variable
          // or parameter is 134 there (captured: gaps-procedures #134)
          if in_proc && failure is None && declared.contains(v.name.to_lower()) {
            failure = Some((redeclared_error(v.name), line))
          }
          declared.add(v.name.to_lower())
          try
            @bind.resolve_type(v.type_, Declaration, @types.default_collation)
          catch {
            _ => ()
          } noraise {
            ty => types[v.name.to_lower()] = ty
          }
        }
      DeclareTable(name, _) => declared.add(name.to_lower())
      // conflicting cursor options are compile errors of the batch: 1048
      // at the statement's line, 1049 (old and new syntax) at line 0
      // (captured: msduck-runs/cursor #029-#034, stmts/cursor-options)
      DeclareCursor(c) | SetCursor(c) => {
        if s.kind is SetCursor(_) {
          check_name(c.name.name, line)
        }
        if failure is None {
          failure = cursor_option_error(c).map(e => {
            (e, if e.number() == 1049 { 0 } else { line })
          })
        }
      }
      // two CREATE TABLEs of one temp table name (also ## and in other
      // branches or after a DROP) fail the whole batch: 2714 state 1 at
      // the second (captured: msduck gaps-temp_tables #015, corpus
      // stmts/temp-duplicate-create)
      CreateTable(ct) if ct.name.base().has_prefix("#") => {
        let base = ct.name.base()
        if failure is None && temp_creates.contains(base.to_lower()) {
          failure = Some(
            (
              @types.sql_error(
                2714,
                "There is already an object named '\{base}' in the database.",
              ),
              line,
            ),
          )
        }
        temp_creates.add(base.to_lower())
      }
      SetVar(n, _, e) => {
        check_name(n, line)
        expr(e, line)
      }
      Select(q) => {
        query_vars(q, x => expr(x, line), n => check_name(n, line))
        if failure is None {
          // 422 is reported on the SELECT's line, 6819 on the WITH's
          failure = match select_shape_error(q) {
            Some((e, true)) =>
              match q.body {
                Select(sel) => Some((e, sel.span.line))
                _ => Some((e, line))
              }
            Some((e, false)) => Some((e, line))
            None => None
          }
        }
        // captured: an undeclared table variable in FROM is 1087 state 2
        // for the whole batch, and at CREATE PROCEDURE (msduck-runs
        // table-variable #014, #038)
        if failure is None {
          match undeclared_table_var(q.body, declared) {
            Some(n) =>
              failure = Some(
                (
                  @types.sql_error(
                    1087,
                    "Must declare the table variable \"\{n}\".",
                    state=2,
                    severity=15,
                  ),
                  line,
                ),
              )
            None => ()
          }
        }
        if failure is None &&
          q.body is Select({ top: Some(t), .. }) &&
          top_constant_error(t, types) is Some(e) {
          failure = Some((e, line))
        }
        if failure is None &&
          offset_fetch_constant_error(q.offset, q.fetch, types) is Some(e) {
          failure = Some((e, line))
        }
        // captured: a variable or parameter as STRING_SPLIT's
        // enable_ordinal is 8748 for the whole batch (msduck string-split
        // #036, #048)
        if failure is None && q.body is Select(sel) {
          for t in sel.from {
            if failure is None {
              failure = string_split_ordinal_error(t)
            }
          }
        }
        // captured: ORDER BY a bare variable is 1008 for the whole batch
        // (msduck order-token-expanded #076)
        if failure is None {
          for i, o in q.order_by {
            if o.expr.kind is Var(_) {
              failure = Some(
                (
                  @types.sql_error(
                    1008,
                    "The SELECT item identified by the ORDER BY number \{i + 1} contains a variable as part of the expression identifying a column position. Variables are only allowed when ordering by an expression referencing a column name.",
                  ),
                  o.expr.span.line,
                ),
              )
              break
            }
          }
        }
      }
      CreateTable({ body, .. }) | AlterTable(_, Add(body, ..)) if failure
        is None =>
        failure = computed_constraint_error(body.columns).map(e => (e, line))
      Print(e) => {
        expr(e, line)
        // captured: PRINT of a sql_variant variable is a compile-time 257
        if failure is None &&
          e.kind is Var(n) &&
          types.get(n.to_lower()) is Some(Variant) {
          failure = Some(
            (
              @types.implicit_conversion_error(
                Variant,
                NVarChar(Some(1), @types.default_collation),
              ),
              line,
            ),
          )
        }
      }
      If(c, a, b) => {
        expr(c, line)
        stmt(a)
        if b is Some(x) {
          stmt(x)
        }
      }
      While(c, b) => {
        expr(c, line)
        stmt(b)
      }
      Block(list) => list.each(stmt)
      TryCatch(a, b) => {
        a.each(stmt)
        b.each(stmt)
      }
      RaisError(args, ..) => {
        args.each(x => expr(x, line))
        if failure is None {
          failure = raiserror_compile_error(args, types).map(e => (e, line))
        }
      }
      Throw(args) => args.each(x => expr(x, line))
      // captured: an unknown DBCC WITH option is 195 state 4 for the
      // whole batch (corpus stmts/tx-dbcc-useroptions)
      Dbcc(_, args, options) => {
        args.each(x => expr(x, line))
        for o in options {
          if failure is None && !dbcc_options.contains(o) {
            failure = Some(
              (
                @types.sql_error(
                  195,
                  "'\{o}' is not a recognized option.",
                  state=4,
                  severity=15,
                ),
                line,
              ),
            )
          }
        }
      }
      // captured: a malformed WAITFOR literal is compile error 148 for the
      // whole batch, not caught by TRY (msduck gaps-transactions #093/#094)
      WaitFor(_, e) => {
        expr(e, line)
        if failure is None &&
          e.kind is StrLit(text, ..) &&
          parse_wait_time(text) is None {
          failure = Some(
            (
              @types.sql_error(
                148,
                "Incorrect time syntax in time string '\{text}' used with WAITFOR.",
                severity=15,
              ),
              line,
            ),
          )
        }
      }
      Use(_) if in_proc && failure is None =>
        failure = Some(
          (
            @types.sql_error(
              154,
              "a USE database statement is not allowed in a procedure, function or trigger.",
              severity=15,
            ),
            line,
          ),
        )
      Insert({ target, top, .. })
      | Update({ target, top, .. })
      | Delete({ target, top, .. })
      | Merge({ target, top, .. }) if failure is None => {
        failure = target_hint_error(target, line)
        // a column assigned twice in one SET list: 264 for the whole batch
        // (captured: dml/compound-assignment)
        if failure is None {
          let lists = match s.kind {
            Update(u) => [u.sets]
            Merge(m) =>
              m.whens.filter_map(w => {
                guard w.action is MergeUpdate(sets) else { None }
                Some(sets)
              })
            _ => []
          }
          for sets in lists {
            if duplicate_set_column(sets) is Some(spelled) {
              // named as in the catalog (captured)
              let name = set_column_name(target, spelled)
              failure = Some(
                (
                  @types.sql_error(
                    264,
                    "The column name '\{name}' is specified more than once in the SET clause or column list of an INSERT. A column cannot be assigned more than one value in the same clause. Modify the clause to make sure that a column is updated only once. If this statement updates or inserts columns into a view, column aliasing can conceal the duplication in your code.",
                  ),
                  line,
                ),
              )
              break
            }
          }
        }
        // INDEX hints on an INSERT/UPDATE/DELETE target (a view too):
        // 1069 for the whole batch; the FROM occurrence may carry them
        // (captured: tail5/b2-hints)
        if failure is None &&
          !(s.kind is Merge(_)) &&
          target.kind is Table(_, hints~, ..) &&
          hints.iter().any(h => h.name == "INDEX") {
          failure = Some(
            (
              @types.sql_error(
                1069,
                "Index hints are only allowed in a FROM or OPTION clause.",
                severity=15,
              ),
              line,
            ),
          )
        }
        // READPAST on an INSERT target: 4102 for the whole batch
        // (captured: tail5/b2-readpast)
        if failure is None &&
          s.kind is Insert(_) &&
          target.kind is Table(_, hints~, ..) &&
          hints.iter().any(h => h.name == "READPAST") {
          failure = Some(
            (
              @types.sql_error(
                4102,
                "The READPAST lock hint is only allowed on target tables of UPDATE and DELETE and on tables specified in an explicit FROM clause.",
                severity=15,
              ),
              line,
            ),
          )
        }
        // captured: a constant DML TOP is checked like SELECT's (msduck-runs
        // merge-top#062/#066/#070)
        if failure is None && top is Some(t) && !t.percent {
          failure = top_constant_error(t, types).map(e => (e, line))
        }
        if failure is None && s.kind is Merge(m) {
          failure = merge_clause_error(m).map(e => (e, line))
        }
      }
      Return(Some(e)) if in_proc => expr(e, line)
      Return(Some(e)) => {
        // RETURN with a value outside a procedure (batch, sp_executesql
        // text): compile error 178 (captured: msduck raiserror-rpc)
        if failure is None {
          failure = Some(
            (
              @types.sql_error(
                178,
                "A RETURN statement with a return value cannot be used in this context.",
                severity=15,
              ),
              line,
            ),
          )
        }
        expr(e, line)
      }
      _ => ()
    }
  }

  for s in stmts {
    stmt(s)
  }
  if failure is None {
    failure = precheck_xml(stmts, types)
  }
  if failure is None {
    failure = precheck_json(stmts)
  }
  failure
}

///|
fn query_vars(
  q : @ast.Query,
  on_expr : (@ast.Expr) -> Unit,
  on_assign : (String) -> Unit,
) -> Unit {
  match q.body {
    Select(s) => {
      for item in s.items {
        match item.kind {
          ExprItem(e, ..) => on_expr(e)
          Assign(n, _, e) => {
            on_assign(n)
            on_expr(e)
          }
          Star(_) => ()
        }
      }
      if s.where_ is Some(w) {
        on_expr(w)
      }
    }
    _ => ()
  }
  for o in q.order_by {
    on_expr(o.expr)
  }
}

///|
/// Pre-order traversal of an expression tree (not into subqueries).
fn walk_expr(e : @ast.Expr, f : (@ast.Expr) -> Unit) -> Unit {
  f(e)
  match e.kind {
    MethodCall(t, _, args) => {
      walk_expr(t, f)
      args.each(x => walk_expr(x, f))
    }
    Unary(_, a)
    | Not(a)
    | Paren(a)
    | IsNull(a, ..)
    | Cast(a, _, ..)
    | Collate(a, _) => walk_expr(a, f)
    Binary(_, a, b)
    | Compare(_, a, b)
    | And(a, b)
    | Or(a, b)
    | AtTimeZone(a, b) => {
      walk_expr(a, f)
      walk_expr(b, f)
    }
    Like(a, b, escape~, ..) => {
      walk_expr(a, f)
      walk_expr(b, f)
      if escape is Some(x) {
        walk_expr(x, f)
      }
    }
    Between(a, b, c, ..) => {
      walk_expr(a, f)
      walk_expr(b, f)
      walk_expr(c, f)
    }
    InList(a, items, ..) => {
      walk_expr(a, f)
      items.each(x => walk_expr(x, f))
    }
    Case(operand~, whens~, else_~) => {
      if operand is Some(o) {
        walk_expr(o, f)
      }
      for w in whens {
        walk_expr(w.0, f)
        walk_expr(w.1, f)
      }
      if else_ is Some(x) {
        walk_expr(x, f)
      }
    }
    Convert(_, a, style~, ..) => {
      walk_expr(a, f)
      if style is Some(s) {
        walk_expr(s, f)
      }
    }
    Call(c) => c.args.each(x => walk_expr(x, f))
    NextValueFor(_, Some(o)) => o.order_by.each(i => walk_expr(i.expr, f))
    _ => ()
  }
}

///|
/// RAISERROR argument errors SQL Server raises while compiling the batch
/// (captured: msduck raiserror-arguments): more than 20 substitution
/// parameters (2747); a variable whose type cannot be substituted (2748).
fn raiserror_compile_error(
  args : Array[@ast.Expr],
  types : Map[String, @types.SqlType],
) -> @types.SqlError? {
  if args.length() > 23 {
    return Some(
      @types.sql_error(
        2747, "Too many substitution parameters for RAISERROR. Cannot exceed 20 substitution parameters.",
      ),
    )
  }
  for k in 3..<args.length() {
    guard args[k].kind is Var(name) else { continue }
    guard types.get(name.to_lower()) is Some(ty) else { continue }
    if !(ty
      is (TinyInt
      | SmallInt
      | Int
      | BigInt
      | Char(_, _)
      | VarChar(_, _)
      | NChar(_, _)
      | NVarChar(_, _)
      | Binary(_)
      | VarBinary(_)
      | Bit)) {
      return Some(
        @types.sql_error(
          2748,
          "Cannot specify \{ty.to_sql()} data type (parameter \{k + 1}) as a substitution parameter.",
        ),
      )
    }
  }
  None
}

///|
/// A constant SELECT TOP count fails the whole batch (class 15; captured:
/// msduck-runs select-top-percent, tail/top-invalid): PERCENT outside
/// 0..100 is 1031, NULL 1014; a row count below 0 is 127, NULL 1060.
fn top_constant_error(
  t : @ast.Top,
  types : Map[String, @types.SqlType],
) -> @types.SqlError? {
  let b = bind_row_count(t.count, types)
  guard b is Some(b) else { return None }
  // a row count of any non-integer type, constant or not, is 1060
  // (captured: tail/top-fractional, DECLARE @d decimal; TOP (@d))
  if !t.percent && !row_count_integer(b) && !(b.kind is Lit(Null)) {
    return Some(top_not_integer_error())
  }
  guard @bind.constant_value(b) is Some(v) else { return None }
  if t.percent {
    if v is Null {
      return Some(top_invalid_error())
    }
    let p = @types.cast(v, b.ty, Float) catch { _ => Null }
    match p {
      Float(p) if p < 0.0 || p > 100.0 => Some(top_percent_error())
      _ => None
    }
  } else if v is Null {
    Some(top_not_integer_error())
  } else {
    match row_count_value(v, b.ty) {
      Some(n) if n < 0L =>
        Some(
          @types.sql_error(
            127,
            "A TOP N or FETCH rowcount value may not be negative.",
            severity=15,
          ),
        )
      _ => None
    }
  }
}

///|
/// Constant OFFSET / FETCH counts fail the whole batch (class 15;
/// captured: query/top-fetch-bigint): OFFSET not an integer or NULL is
/// 10743, negative 10742; FETCH not an integer or NULL is 1060, below 1
/// 10744. Bigint overflow is left to run time (8115).
fn offset_fetch_constant_error(
  offset : @ast.Expr?,
  fetch : @ast.Expr?,
  types : Map[String, @types.SqlType],
) -> @types.SqlError? {
  if offset is Some(o) && bind_row_count(o, types) is Some(b) {
    let v = @bind.constant_value(b)
    if !row_count_integer(b) || v is Some(Null) {
      return Some(
        @types.sql_error(
          10743,
          "The number of rows provided for a OFFSET clause must be an integer.",
          severity=15,
        ),
      )
    }
    if v is Some(v) && row_count_value(v, b.ty) is Some(n) && n < 0L {
      return Some(
        @types.sql_error(
          10742,
          "The offset specified in a OFFSET clause may not be negative.",
          severity=15,
        ),
      )
    }
  }
  if fetch is Some(f) && bind_row_count(f, types) is Some(b) {
    let v = @bind.constant_value(b)
    if !row_count_integer(b) || v is Some(Null) {
      return Some(top_not_integer_error())
    }
    if v is Some(v) && row_count_value(v, b.ty) is Some(n) && n < 1L {
      return Some(
        @types.sql_error(
          10744,
          "The number of rows provided for a FETCH clause must be greater then zero.",
          severity=15,
        ),
      )
    }
  }
  None
}

///|
fn bind_row_count(
  e : @ast.Expr,
  types : Map[String, @types.SqlType],
) -> @ir.Expr? {
  let vars : Map[String, @bind.VarInfo] = Map([])
  for k, ty in types {
    vars[k] = { slot: vars.length(), ty, }
  }
  Some(@bind.bind_expr(@bind.Env::new(vars), e)) catch {
    _ => None
  }
}

///|
/// A TOP / FETCH / OFFSET row count must be an integer type, or a constant
/// of type numeric with scale 0 (an integer literal beyond int: captured
/// query/top-fetch-bigint, `TOP 2147483648`, `TOP (1 * 2147483648)` and
/// `CAST(2 AS numeric(5,0))` run; decimal(p,0), and numeric variables or
/// subqueries, are 1060).
fn row_count_integer(b : @ir.Expr) -> Bool {
  b.ty.family() is FInteger ||
  (b.ty is Numeric(_, 0) && @bind.constant_value(b) is Some(_))
}

///|
/// The constant row count as bigint; None when it overflows (run time
/// raises 8115 then).
fn row_count_value(v : @types.Value, ty : @types.SqlType) -> Int64? {
  @types.cast(v, ty, BigInt).as_int64() catch {
    _ => None
  }
}

///|
fn top_not_integer_error() -> @types.SqlError {
  @types.sql_error(
    1060,
    "The number of rows provided for a TOP or FETCH clauses row count parameter must be an integer.",
    severity=15,
  )
}

///|
fn top_invalid_error() -> @types.SqlError {
  @types.sql_error(
    1014,
    "A TOP or FETCH clause contains an invalid value.",
    severity=15,
  )
}

///|
fn top_percent_error() -> @types.SqlError {
  @types.sql_error(
    1031,
    "Percent values must be between 0 and 100.",
    severity=15,
  )
}

///|
/// The first table variable a query's FROM trees read that is not declared
/// (derived tables included; subqueries in expressions are not walked).
fn undeclared_table_var(b : @ast.QueryBody, declared : Set[String]) -> String? {
  fn refs(r : @ast.TableRef) -> String? {
    match r.kind {
      TableVar(n, ..) if !declared.contains(n.to_lower()) => Some(n)
      Join(_, a, c, ..) =>
        match refs(a) {
          Some(n) => Some(n)
          None => refs(c)
        }
      Pivot(src, _, ..) => refs(src)
      Derived(q, ..) => undeclared_table_var(q.body, declared)
      _ => None
    }
  }
  match b {
    Select(s) => {
      for r in s.from {
        match refs(r) {
          Some(n) => return Some(n)
          None => ()
        }
      }
      None
    }
    SetOperation(_, l, r) =>
      match undeclared_table_var(l, declared) {
        Some(n) => Some(n)
        None => undeclared_table_var(r, declared)
      }
    Nested(q) => undeclared_table_var(q.body, declared)
  }
}

///|
/// MERGE WHEN clauses, checked for the whole batch (captured: msduck-runs
/// merge-execution #043/#044, tail/merge-when-clauses): an action repeated
/// within one WHEN kind is 10714 (class 15); a clause after one of the
/// same kind without a search condition is 5324.
fn merge_clause_error(m : @ast.Merge) -> @types.SqlError? {
  let kinds : Array[(@ast.MergeMatch, String)] = [
    (Matched, "WHEN MATCHED"),
    (NotMatchedByTarget, "WHEN NOT MATCHED"),
    (NotMatchedBySource, "WHEN NOT MATCHED BY SOURCE"),
  ]
  for k in kinds {
    let (kind, label) = k
    let list = m.whens.filter(w => w.match_ == kind)
    let seen : Array[String] = []
    for w in list {
      let action = match w.action {
        MergeUpdate(_) => "UPDATE"
        MergeDelete => "DELETE"
        MergeInsert(..) => "INSERT"
      }
      if seen.contains(action) {
        return Some(
          @types.sql_error(
            10714,
            "An action of type '\{label}' cannot appear more than once in a '\{action}' clause of a MERGE statement.",
            severity=15,
          ),
        )
      }
      seen.push(action)
    }
    for i in 1..<list.length() {
      if list[i - 1].condition is None {
        return Some(
          @types.sql_error(
            5324,
            "In a MERGE statement, a '\{label}' clause with a search condition cannot appear after a '\{label}' clause with no search condition.",
          ),
        )
      }
    }
  }
  None
}

///|
/// The 10753 state of a window-only function called without OVER.
fn window_over_state(name : String) -> Int? {
  match name.to_upper() {
    "ROW_NUMBER"
    | "RANK"
    | "DENSE_RANK"
    | "NTILE"
    | "CUME_DIST"
    | "PERCENT_RANK" => Some(3)
    "LAG" | "LEAD" | "FIRST_VALUE" | "LAST_VALUE" => Some(1)
    _ => None
  }
}

///|
/// Arity of window-only functions: 4114 "The function 'X' takes exactly n
/// argument(s)." and 10755 for LAG/LEAD, naming the function as written.
fn window_arity_error(name : String, n : Int) -> @types.SqlError? {
  let exact = match name.to_upper() {
    "ROW_NUMBER" | "RANK" | "DENSE_RANK" | "PERCENT_RANK" | "CUME_DIST" => 0
    "NTILE" => 1
    "LAG" | "LEAD" =>
      return if n < 1 || n > 3 {
        Some(
          @types.sql_error(
            10755,
            "The function '\{name}' takes between 1 and 3 arguments.",
            severity=15,
          ),
        )
      } else {
        None
      }
    _ => return None
  }
  if n == exact {
    None
  } else {
    Some(
      @types.sql_error(
        4114,
        "The function '\{name}' takes exactly \{exact} argument(s).",
        severity=15,
      ),
    )
  }
}

///|
/// 134 "The variable name '@a' has already been declared. ..." (class 15).
fn redeclared_error(name : String) -> @types.SqlError {
  @types.sql_error(
    134,
    "The variable name '\{name}' has already been declared. Variable names must be unique within a query batch or stored procedure.",
    severity=15,
  )
}

///|
/// Table hints SQL Server recognizes (anything else is 321).
let known_table_hints : Array[String] = [
  "NOEXPAND", "INDEX", "FORCESEEK", "FORCESCAN", "HOLDLOCK", "NOLOCK", "NOWAIT",
  "PAGLOCK", "READCOMMITTED", "READCOMMITTEDLOCK", "READPAST", "READUNCOMMITTED",
  "REPEATABLEREAD", "ROWLOCK", "SERIALIZABLE", "SNAPSHOT", "SPATIAL_WINDOW_MAX_CELLS",
  "TABLOCK", "TABLOCKX", "UPDLOCK", "XLOCK", "KEEPIDENTITY", "KEEPDEFAULTS", "IGNORE_CONSTRAINTS",
  "IGNORE_TRIGGERS", "FASTFIRSTROW",
]

///|
/// Compile-time checks of a DML target's table hints, which fail the whole
/// batch (captured: msduck gaps-merge #006/#007, stmts/merge-hints): an
/// unknown hint is 321 (statement line), NOLOCK / READUNCOMMITTED on a
/// target is 1065, which SQL Server always reports at line 15.
fn target_hint_error(
  target : @ast.TableRef,
  line : Int,
) -> (@types.SqlError, Int)? {
  let hints = match target.kind {
    Table(_, hints~, ..) | TableVar(_, hints~, ..) => hints
    _ => []
  }
  for h in hints {
    if !known_table_hints.contains(h.name) {
      return Some(
        (
          @types.sql_error(
            321,
            "\"\{h.name.to_lower()}\" is not a recognized table hints option.",
            severity=15,
          ),
          line,
        ),
      )
    }
  }
  for h in hints {
    if h.name == "NOLOCK" || h.name == "READUNCOMMITTED" {
      return Some(
        (
          @types.sql_error(
            1065,
            "The NOLOCK and READUNCOMMITTED lock hints are not allowed for target tables of INSERT, UPDATE, DELETE or MERGE statements.",
            severity=15,
          ),
          15,
        ),
      )
    }
  }
  None
}

///|
/// True when an object name has a (non-empty) database part.
fn has_database_part(name : @ast.ObjectName) -> Bool {
  let n = name.parts.length()
  n >= 3 && name.parts[n - 3].name != ""
}

///|
/// A non-persisted computed column takes only UNIQUE / PRIMARY KEY
/// constraints: a column-level CHECK, REFERENCES, NULL or NOT NULL on it is
/// compile error 8183 for the whole batch (captured: corpus
/// catalog/computed-forward-refs; a table-level CHECK naming it is 1764
/// when the statement runs).
fn computed_constraint_error(
  columns : Array[@ast.ColumnDef],
) -> @types.SqlError? {
  for c in columns {
    if c.computed is Some(_) &&
      !c.persisted &&
      (
        c.nullable is Some(_) ||
        c.constraints
        .iter()
        .any(k => k.kind is (ColCheck(_, ..) | ColReferences(_)))
      ) {
      return Some(
        @types.sql_error(
          8183, "Only UNIQUE or PRIMARY KEY constraints can be created on computed columns, while CHECK, FOREIGN KEY, and NOT NULL constraints require that computed columns be persisted.",
        ),
      )
    }
  }
  None
}

///|
/// Whole-batch errors from a SELECT's shape (captured:
/// query/cte-assignment-select, query/unused-cte):
/// - an assignment SELECT with FOR XML / FOR JSON is 6819;
/// - a WITH whose SELECT is a bare constant projection (no FROM, WHERE,
///   GROUP BY, HAVING, TOP, DISTINCT, ORDER BY, subquery or aggregate) is
///   422: SQL Server never references the CTE. Calls other than the
///   simplest forms are left alone (only constants, variables, operators
///   and CASE/CAST were captured), so the check stays narrow.
/// The flag says the error is reported on the SELECT's own line.
fn select_shape_error(q : @ast.Query) -> (@types.SqlError, Bool)? {
  guard q.body is Select(sel) else { return None }
  let assigns = sel.items.iter().any(i => i.kind is Assign(_, _, _))
  if assigns && q.for_clause is Some(_) {
    return Some((@bind.for_assignment_error(), false))
  }
  if q.ctes.is_empty() ||
    !sel.from.is_empty() ||
    sel.where_ is Some(_) ||
    !sel.group_by.is_empty() ||
    sel.having is Some(_) ||
    sel.top is Some(_) ||
    sel.distinct ||
    !q.order_by.is_empty() ||
    q.offset is Some(_) ||
    q.for_clause is Some(_) {
    return None
  }
  let mut simple = true
  for i in sel.items {
    let e = match i.kind {
      ExprItem(e, ..) | Assign(_, _, e) => e
      Star(_) => {
        simple = false
        break
      }
    }
    walk_expr(e, x => {
      match x.kind {
        Subquery(_)
        | Exists(_)
        | InQuery(_, _, ..)
        | Quantified(_, _, _, _)
        | Call(_)
        | MethodCall(_, _, _)
        | NextValueFor(_, _)
        | Parse(_, _, ..)
        | Column(_) => simple = false
        _ => ()
      }
    })
  }
  if !simple {
    return None
  }
  Some(
    (
      @types.sql_error(
        422,
        "Common table expression defined but not used.",
        state=4,
      ),
      true,
    ),
  )
}

///|
/// The first column a SET list assigns more than once (by its last name part,
/// case-insensitively), spelled as at its first assignment.
fn duplicate_set_column(sets : Array[@ast.SetClause]) -> String? {
  let seen : Map[String, String] = Map([])
  for s in sets {
    guard s.target is SetColumn(parts) else { continue }
    let name = parts[parts.length() - 1].name
    match seen.get(name.to_lower()) {
      Some(first) => return Some(first)
      None => seen[name.to_lower()] = name
    }
  }
  None
}
