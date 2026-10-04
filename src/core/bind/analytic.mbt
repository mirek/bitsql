///|
/// Analytic binding rules captured in harness/corpus/analytic: window frame
/// validation, PERCENTILE_CONT / PERCENTILE_DISC, STRING_AGG separator and
/// WITHIN GROUP checks, APPROX_COUNT_DISTINCT restrictions.

///|
/// Window frame checks, in SQL Server's order: functions that take no
/// frame (10752), a frame without ORDER BY (10756), RANGE with offsets
/// (4194), impossible frame shapes (4193).
fn check_frame(
  name : String,
  over : @ast.Over,
  fr : @ast.Frame,
) -> Unit raise @types.SqlError {
  let no_frame_state = match name {
    "ROW_NUMBER"
    | "RANK"
    | "DENSE_RANK"
    | "NTILE"
    | "PERCENT_RANK"
    | "CUME_DIST" => 3
    "LAG" | "LEAD" | "PERCENTILE_CONT" | "PERCENTILE_DISC" => 1
    _ => 0
  }
  if no_frame_state > 0 {
    raise err(
      10752,
      "The function '\{name}' may not have a window frame.",
      state=no_frame_state,
      severity=15,
    )
  }
  if over.order_by.is_empty() {
    raise err(
      10756,
      "Window frame with ROWS or RANGE must have an ORDER BY clause.",
      severity=15,
    )
  }
  let end : @ast.FrameBound = match fr.end {
    Some(e) => e
    None => CurrentRow
  }
  if fr.unit is Range &&
    (
      fr.start is (Preceding(_) | Following(_)) ||
      end is (Preceding(_) | Following(_))
    ) {
    raise err(
      4194, "RANGE is only supported with UNBOUNDED and CURRENT ROW window frame delimiters.",
    )
  }
  let invalid = (state : Int, shape : String) => {
    err(
      4193,
      "'\{shape}' is not a valid window frame and cannot be used with the OVER clause.",
      state~,
    )
  }
  match (fr.start, end) {
    (Following(_), Preceding(_)) =>
      raise invalid(1, "BETWEEN ... FOLLOWING AND ... PRECEDING")
    (Following(_), CurrentRow) =>
      raise invalid(4, "BETWEEN ... FOLLOWING AND CURRENT ROW")
    (CurrentRow, Preceding(_)) =>
      raise invalid(5, "BETWEEN CURRENT ROW AND ... PRECEDING")
    _ => ()
  }
}

///|
/// 5308 for an integer-literal sort key, 5309 (if `constants`) for any
/// other constant key, 130 for a subquery.
fn check_aggregate_order(
  env : Env,
  items : Array[@ast.OrderItem],
  constants~ : Bool,
) -> Unit raise @types.SqlError {
  for o in items {
    if any_expr(o.expr, _ => false, subqueries=true) {
      raise nested_aggregate_error()
    }
    if o.expr.kind is IntLit(_) {
      raise err(
        5308, "Windowed functions, aggregates and NEXT VALUE FOR functions do not support integer indices as ORDER BY clause expressions.",
      )
    }
    if constants && is_constant(bind_expr(env, o.expr)) {
      raise err(
        5309, "Windowed functions, aggregates and NEXT VALUE FOR functions do not support constants as ORDER BY clause expressions.",
      )
    }
  }
}

///|
/// PERCENTILE_CONT / PERCENTILE_DISC (p) WITHIN GROUP (ORDER BY key)
/// OVER ([PARTITION BY ...]): float for CONT, the key's type for DISC.
fn bind_percentile(
  env : Env,
  name : String,
  call : @ast.FuncCall,
  partition : Array[@ir.Expr],
) -> @ir.WindowCall raise @types.SqlError {
  let over = call.over.unwrap()
  if call.within_group.is_empty() {
    raise err(
      10754,
      "The function '\{name}' must have a WITHIN GROUP clause.",
      severity=15,
    )
  }
  if !over.order_by.is_empty() {
    raise err(
      10758,
      "The function '\{name}' may not have ORDER BY in OVER clause.",
      severity=15,
    )
  }
  if call.within_group.length() != 1 {
    raise err(
      10751,
      "The ORDER BY in WITHIN GROUP clause of '\{name}' function must have exactly one expression.",
      severity=15,
    )
  }
  if call.args.length() != 1 {
    raise err(174, "The \{name} function requires 1 argument(s).", severity=15)
  }
  // captured (msduck percentile-runtime-fraction): any expression without
  // column references is accepted (@p + 0, ABS(@p), (SELECT .5), RAND()...)
  // ... but column references, also inside a subquery with a FROM clause,
  // are 8726, and NEXT VALUE FOR is 11720
  if any_expr(call.args[0], x => x.kind is NextValueFor(_, _), subqueries=false) {
    raise err(
      11720,
      "NEXT VALUE FOR function is not allowed in the TOP, OVER, OUTPUT, ON, WHERE, GROUP BY, HAVING, or ORDER BY clauses.",
      severity=15,
    )
  }
  if any_expr(call.args[0], x => {
      match x.kind {
        Column(_) => true
        Subquery(q) => query_reads_tables(q)
        _ => false
      }
    }) {
    raise err(8726, "Input parameter of \{name} function must be a constant.")
  }
  let p = bind_expr(env, call.args[0])
  check_aggregate_order(env, call.within_group, constants=true)
  let o = call.within_group[0]
  let key = bind_expr(env, o.expr)
  let cont = name == "PERCENTILE_CONT"
  // captured: PERCENTILE_DISC over xml is 305, even over no rows
  // (msduck percentile-order-type #166-#168)
  if !cont && key.ty is Xml {
    raise xml_not_comparable()
  }
  if !cont && key.ty is Json {
    raise json_not_comparable(2)
  }
  // bit is accepted (msduck percentile-order-type); max types print as
  // varchar(max) in the message
  if cont &&
    !(key.ty.family() is (FInteger | FDecimal | FMoney | FFloat) ||
    key.ty is Bit) {
    raise err(
      402,
      "The data types \{p.ty.message_name()} and \{key.ty.clash_name()} are incompatible in the percentile_cont operator.",
    )
  }
  {
    func: if cont {
      PercentileCont
    } else {
      PercentileDisc
    },
    args: [p],
    partition,
    partition_collations: partition.map(x => x.ty.collation()),
    order: [{ expr: key, desc: o.desc, collation: key.ty.collation(), }],
    frame: None,
    ignore_nulls: false,
    ty: if cont {
      Float
    } else {
      key.ty
    },
  }
}

///|
/// STRING_AGG's separator: a character string literal (also `'a' + 'b'`)
/// or variable, unicode only if the value is (captured:
/// analytic/string-agg-checks: 130, 8116, 8733).
fn check_string_agg_separator(
  value : @ir.Expr,
  sep_ast : @ast.Expr,
  sep : @ir.Expr,
) -> Unit raise @types.SqlError {
  if any_expr(sep_ast, _ => false, subqueries=true) {
    raise nested_aggregate_error()
  }
  let null_lit = sep.kind is Lit(Null) && sep.ty is Int
  // a constant NULL (CAST(NULL AS nvarchar(10))) counts as a literal
  // (msduck string-agg#006)
  let null_const = is_constant(sep) && try_fold(sep) is Some(Null)
  match sep.ty {
    Char(_, _) | VarChar(_, _) => ()
    NChar(_, _) | NVarChar(_, _) =>
      if value.ty is (Char(_, _) | VarChar(_, _)) {
        raise bad_arg_type(sep.ty, 2, "string_agg")
      }
    _ if null_lit => ()
    // sql_variant values take a variant separator (variant/functions.sql)
    Variant if value.ty is Variant => ()
    t => raise bad_arg_type(t, 2, "string_agg")
  }
  let literal = (e : @ast.Expr) => {
    fn go(e : @ast.Expr) -> Bool {
      match e.kind {
        StrLit(_, ..) | Null => true
        Paren(a) => go(a)
        Binary(Add, a, b) => go(a) && go(b)
        _ => false
      }
    }
    go(e)
  }
  if !(literal(sep_ast) || sep_ast.kind is Var(_) || null_const) {
    raise err(
      8733, "Separator parameter for STRING_AGG must be a string literal or variable.",
    )
  }
  if sep.ty is (VarChar(None, _) | NVarChar(None, _)) {
    raise err(
      8734, "Separator parameter for STRING_AGG cannot be large object type such as VARCHAR(MAX) or NVARCHAR(MAX).",
    )
  }
}

///|
/// Scalar-call names of analytic functions used outside their allowed
/// shape (bind_call_more hook).
fn bind_analytic_fn(
  name : String,
  call : @ast.FuncCall,
) -> Unit raise @types.SqlError {
  ignore(call)
  match name {
    "PERCENTILE_CONT" | "PERCENTILE_DISC" =>
      raise err(
        10753,
        "The function '\{name}' must have an OVER clause.",
        state=3,
        severity=15,
      )
    _ => ()
  }
}

///|
/// Aggregates that cannot merge subaggregates under ROLLUP / CUBE /
/// GROUPING SETS (8710; captured for STRING_AGG). APPROX_COUNT_DISTINCT
/// there accumulates its sketch across groups in SQL Server (captured
/// probe: ROLLUP over a,b,c gave 2,4,4,4), which bitsql does not model.
fn check_grouping_sets_agg(
  a : @ir.AggCall,
  rolled : Bool,
) -> Unit raise @types.SqlError {
  if !rolled {
    return
  }
  match a.func {
    StringAgg =>
      raise err(
        8710, "Aggregate functions that are used with CUBE, ROLLUP, or GROUPING SET queries must provide for the merging of subaggregates. To fix this problem, remove the aggregate function or write the query using UNION ALL over GROUP BY clauses.",
      )
    ApproxCountDistinct =>
      raise @types.not_supported(
        "APPROX_COUNT_DISTINCT with ROLLUP, CUBE or GROUPING SETS",
        number=@types.EMU_APPROX_COUNT_DISTINCT,
      )
    _ => ()
  }
}

///|
/// GENERATE_SERIES(start, stop [, step]) (captured: analytic/generate-series):
/// integer arguments must share one type (5373 state 1 for start/stop, 2
/// for step); decimal/numeric ones unify to the widest integral part and
/// scale; any other type is 8116 for the first such argument (state = its
/// position). Both errors are followed by one 206 "incompatible with void
/// type" per argument. Untyped NULL arguments take the others' type; the
/// column is nullable only when some typed argument is.
fn bind_generate_series(
  env : Env,
  name : @ast.ObjectName,
  args : Array[@ast.Expr],
  columns : Array[@ast.Ident],
  q : String,
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  if name.parts.length() > 1 {
    raise err(208, "Invalid object name '\{object_text(name)}'.")
  }
  if !columns.is_empty() {
    raise err(
      195,
      "'GENERATE_SERIES' is not a recognized function name.",
      state=15,
      severity=15,
    )
  }
  if args.length() < 2 {
    raise err(
      313,
      "An insufficient number of arguments were supplied for the procedure or function GENERATE_SERIES.",
      state=3,
    )
  }
  if args.length() > 3 {
    raise err(
      8144,
      "Procedure or function GENERATE_SERIES has too many arguments specified.",
      state=3,
    )
  }
  let penv = plan_env(env)
  let bound = args.map(a => bind_expr(penv, a))
  let untyped = (e : @ir.Expr) => e.kind is Lit(Null) && e.ty is Int
  let clash = (first : @types.SqlError) => {
    env.deferred.push(first)
    let last = bound.length() - 1
    for i in 0..<last {
      env.deferred.push(
        err(
          206,
          "Operand type clash: \{bound[i].ty.base_name()} is incompatible with void type",
          state=2,
        ),
      )
    }
    err(
      206,
      "Operand type clash: \{bound[last].ty.base_name()} is incompatible with void type",
      state=2,
    )
  }
  for i, b in bound {
    if untyped(b) {
      continue
    }
    if !(b.ty
      is (TinyInt | SmallInt | Int | BigInt | Decimal(_, _) | Numeric(_, _))) {
      raise clash(bad_arg_type(b.ty, i + 1, "generate_series", state=i + 1))
    }
  }
  let typed = bound.filter(b => !untyped(b))
  let mismatch = (a : @types.SqlType, b : @types.SqlType) => {
    match (a, b) {
      // decimal(10,2) with decimal(5,1) is fine; decimal with numeric is
      // not (captured probe: GENERATE_SERIES(@d decimal(5,1), 3.0) is 5373)
      (Decimal(_, _), Decimal(_, _)) | (Numeric(_, _), Numeric(_, _)) => false
      _ => a != b
    }
  }
  for i, b in bound {
    if untyped(b) || typed.is_empty() {
      continue
    }
    if mismatch(typed[0].ty, b.ty) {
      raise clash(
        err(
          5373,
          "All the input parameters should be of the same type. Supported types are tinyint, smallint, int, bigint, decimal and numeric.",
          state=if i == 2 { 2 } else { 1 },
        ),
      )
    }
  }
  let ty : @types.SqlType = if typed.is_empty() {
    Int
  } else {
    match typed[0].ty {
      Decimal(_, _) | Numeric(_, _) => {
        let mut int_digits = 0
        let mut scale = 0
        for b in typed {
          match b.ty {
            Decimal(p, s) | Numeric(p, s) => {
              int_digits = if p - s > int_digits { p - s } else { int_digits }
              scale = if s > scale { s } else { scale }
            }
            _ => ()
          }
        }
        let p = if int_digits + scale > 38 { 38 } else { int_digits + scale }
        match typed[0].ty {
          Numeric(_, _) => Numeric(p, scale)
          _ => Decimal(p, scale)
        }
      }
      t => t
    }
  }
  // captured: integer results are nullable when an argument is (CAST,
  // variables); decimal results were NOT NULL even over CASTs
  let nullable = typed.is_empty() ||
    (
      !(ty is (Decimal(_, _) | Numeric(_, _))) &&
      typed.iter().any(b => b.nullable)
    )
  let conv = bound.map(b => coerce(b, ty))
  // a constant zero step is a compile-time error (state 1); a variable's
  // zero is found at run time (state 2)
  if conv.length() > 2 && is_constant(conv[2]) {
    let zero = match try_fold(conv[2]) {
      Some(Decimal(d)) => d.is_zero()
      Some(v) => v.as_int64() == Some(0L)
      None => false
    }
    if zero {
      raise err(
        4199, "Argument value 0 is invalid for argument 3 of generate_series function.",
      )
    }
  }
  (
    TableFunc(GenerateSeries(ty), conv),
    [{ qualifier: q, name: "value", ty, nullable, origin: SetOperation, }],
  )
}

///|
/// The TABLESAMPLE pseudo-hint the parser attaches to a table, if any.
fn tablesample_hint(hints : Array[@ast.TableHint]) -> @ast.TableHint? {
  for h in hints {
    if h.name == "TABLESAMPLE" {
      return Some(h)
    }
  }
  None
}

///|
/// Validates TABLESAMPLE on a local table and returns whether the sample
/// is empty (0 PERCENT); 100 PERCENT keeps every row. SQL Server samples
/// whole pages for anything else, nondeterministically even with
/// REPEATABLE, so other sizes raise an Emulator error (captured:
/// analytic/tablesample; 476, 479, 482, 497).
fn bind_tablesample(
  h : @ast.TableHint,
  table : String,
) -> Bool raise @types.SqlError {
  let size = h.args[0]
  let unit = h.args[1]
  let seed = h.args.get(2)
  for t in [Some(size), seed] {
    match t {
      Some(v) if v.has_prefix("@") =>
        raise err(
          497,
          "Variables are not allowed in the TABLESAMPLE or REPEATABLE clauses.",
          severity=15,
        )
      Some("NULL") =>
        raise err(
          482,
          "Non-constant or invalid expression is in the TABLESAMPLE or the REPEATABLE clause.",
          state=2,
          severity=15,
        )
      _ => ()
    }
  }
  let number = (text : String) => {
    match
      @types.cast(
        String(text),
        VarChar(Some(40), @types.default_collation),
        Float,
      ) {
      Float(f) => f
      _ => 0.0
    }
  }
  let bad_rows = (text : String) => {
    err(
      479,
      "Invalid ROWS value or REPEATABLE seed \"\{text}\" in the TABLESAMPLE clause for table \"\{table}\". The value or seed must be greater than 0.",
      state=0,
      severity=15,
    )
  }
  let n = number(size)
  if unit == "PERCENT" && (n < 0.0 || n > 100.0) {
    raise err(
      476,
      "Invalid PERCENT tablesample size \"\{fixed6(n)}\" for table \"\{table}\". The PERCENT tablesample size must be between 0 and 100.",
      state=0,
      severity=15,
    )
  }
  if unit == "ROWS" && n <= 0.0 {
    raise bad_rows(size)
  }
  if seed is Some(sd) && number(sd) <= 0.0 {
    raise bad_rows(sd)
  }
  if unit == "PERCENT" && n == 100.0 {
    return false
  }
  if unit == "PERCENT" && n == 0.0 {
    return true
  }
  raise @types.not_supported(
    "TABLESAMPLE other than 0 or 100 PERCENT (SQL Server samples whole pages nondeterministically)",
    number=@types.EMU_TABLESAMPLE,
  )
}

///|
/// `%f` formatting (6 decimals) of a sample size for message 476.
fn fixed6(x : Double) -> String {
  let neg = x < 0.0
  let scaled = (if neg { -x } else { x }) * 1000000.0
  let n = (scaled + 0.5).floor().to_int64()
  let int_part = n / 1000000L
  let frac = (n % 1000000L).to_string()
  let pad = "000000".view(end_offset=6 - frac.length()).to_owned()
  (if neg { "-" } else { "" }) + int_part.to_string() + "." + pad + frac
}

///|
/// True when a query (or any part of a set operation) has a FROM clause.
fn query_reads_tables(q : @ast.Query) -> Bool {
  fn body(b : @ast.QueryBody) -> Bool {
    match b {
      Select(s) => !s.from.is_empty()
      SetOperation(_, a, c) => body(a) || body(c)
      Nested(n) => query_reads_tables(n)
    }
  }
  body(q.body)
}

///|
/// `NEXT VALUE FOR seq OVER (ORDER BY ...)` as a window call (captured:
/// tail5/b1-next-value-over; the OVER clause shape was checked by the
/// parser: 11716/11718/11737).
fn bind_next_value_window(
  env : Env,
  e : @ast.Expr,
  over : @ast.Over,
) -> @ir.WindowCall raise @types.SqlError {
  for o in over.order_by {
    if o.expr.kind is IntLit(_) {
      raise err(
        5308, "Windowed functions, aggregates and NEXT VALUE FOR functions do not support integer indices as ORDER BY clause expressions.",
      )
    }
  }
  let order = over.order_by.map(o => {
    let k = bind_expr(env, o.expr)
    @ir.SortKey::{ expr: k, desc: o.desc, collation: k.ty.collation(), }
  })
  let call = bind_expr(env, e)
  {
    func: NextValue,
    args: [call],
    partition: [],
    partition_collations: [],
    order,
    frame: None,
    ty: call.ty,
    ignore_nulls: false,
  }
}
