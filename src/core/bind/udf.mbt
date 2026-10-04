// User-defined function calls (scalar in expressions, table-valued in FROM /
// APPLY). Rules captured in harness/corpus/udf/*.sql: arguments convert to
// the parameter types, a parameter default is used only for an explicit
// DEFAULT argument, scalar results are nullable computed columns.

///|
/// Nesting limit for expanding views and inline functions into one plan.
let max_module_nesting : Int = 32

///|
/// Arguments of a user function call converted to its parameter types.
/// `state` is 2 for scalar calls and 3 for table-valued ones (captured
/// 313 / 8144 states).
fn bind_user_args(
  env : Env,
  f : UserFunction,
  written : String,
  args : Array[@ast.Expr],
  state : Int,
) -> Array[@ir.Expr] raise @types.SqlError {
  if args.length() > f.params.length() {
    raise err(
      8144,
      "Procedure or function \{written} has too many arguments specified.",
      state~,
    )
  }
  if args.length() < f.params.length() {
    raise err(
      313,
      "An insufficient number of arguments were supplied for the procedure or function \{written}.",
      state~,
    )
  }
  let out = []
  for i, p in f.params {
    let a = args[i]
    if p.table_type is Some(tn) {
      // a READONLY table-valued parameter takes a table variable; the
      // function receives its table id
      let t = table_arg(env, a, tn)
      out.push(mk(Lit(Int(t.id)), Int, false))
      continue
    }
    let bound = if a.kind is Default {
      match p.default_ {
        Some(d) => bind_expr(Env::new(Map([]), collation=env.collation), d)
        // DEFAULT for a parameter without one is NULL (captured)
        None => mk(Lit(Null), p.ty, true)
      }
    } else {
      bind_expr(env, a)
    }
    out.push(convert_arg(bound, p.ty))
  }
  out
}

///|
/// The table variable passed for a table-valued parameter of type `tn`;
/// anything else is 206 (captured for procedures: "Operand type clash: int
/// is incompatible with IdList").
fn table_arg(
  env : Env,
  a : @ast.Expr,
  tn : String,
) -> TableBinding raise @types.SqlError {
  if a.kind is Var(name) {
    match env.table_var(name) {
      Some(t) => return t
      None => ()
    }
  }
  let b = bind_expr(env, a)
  raise err(
    206,
    "Operand type clash: \{b.ty.clash_name()} is incompatible with \{tn}",
    state=2,
  )
}

///|
/// Implicit conversion of an argument; incompatible types are 206 state 2
/// (captured: date argument for an int parameter).
fn convert_arg(
  e : @ir.Expr,
  ty : @types.SqlType,
) -> @ir.Expr raise @types.SqlError {
  if e.ty == ty {
    return e
  }
  // a bare NULL converts to anything (captured json4/procs: dbo.fj(NULL)
  // for a json parameter)
  if is_untyped_null(e) {
    return typed_null(ty)
  }
  if !@types.can_convert_implicitly(e.ty, ty) {
    raise @types.type_clash_error(e.ty, ty)
  }
  { kind: Cast(e, try_=false, style=None), ty, nullable: e.nullable, }
}

///|
/// `schema.f(args)` in an expression: a scalar user function. Table-valued
/// functions and unknown names are 4121.
fn bind_scalar_udf(
  env : Env,
  call : @ast.FuncCall,
) -> @ir.Expr raise @types.SqlError {
  let written = object_text(call.name)
  let (f, ret) = match (env.catalog.function)(call.name) {
    Some({ kind: Scalar(ret), .. } as f) => (f, ret)
    _ =>
      raise err(
        4121,
        "Cannot find either column \"\{call.name.parts[0].name}\" or the user-defined function or aggregate \"\{written}\", or the name is ambiguous.",
      )
  }
  if call.star || call.distinct || call.over is Some(_) {
    raise @types.not_supported("this form of user-defined function call")
  }
  let args = bind_user_args(env, f, written, call.args, 2)
  // captured: results are nullable computed columns (flags 33)
  mk(UserFn(f.id, args), ret, true)
}

///|
/// A user table-valued function in FROM / APPLY. None when `name` is not
/// one (the caller then tries built-ins).
fn bind_user_tvf(
  env : Env,
  name : @ast.ObjectName,
  args : Array[@ast.Expr],
  alias_ : @ast.Ident?,
  columns : Array[@ast.Ident],
) -> (@ir.Plan, Array[ColumnRef])? raise @types.SqlError {
  let f = match (env.catalog.function)(name) {
    Some(f) => f
    None => return None
  }
  let written = object_text(name)
  if f.kind is Scalar(_) {
    // captured: a scalar function in FROM is 208 state 224
    raise err(208, "Invalid object name '\{written}'.", state=224)
  }
  if !columns.is_empty() {
    raise err(
      317,
      "Table-valued function '\{name.base()}' cannot have a column alias.",
    )
  }
  let q = match alias_ {
    Some(a) => a.name.to_lower()
    None => name.base().to_lower()
  }
  // arguments see the caller's scope like OPENJSON's (APPLY outer rows)
  let bound = bind_user_args(plan_env(env), f, written, args, 3)
  match f.kind {
    Inline(query) => {
      if env.nest >= max_module_nesting {
        raise @types.not_supported(
          "views or inline functions nested more than 32 levels",
        )
      }
      let vars : Map[String, VarInfo] = Map([])
      let table_params : Map[String, TableBinding] = Map([])
      for i, p in f.params {
        match p.table_type {
          Some(tn) =>
            table_params[p.name.to_lower()] = table_arg(
              plan_env(env),
              args[i],
              tn,
            )
          None => vars[p.name.to_lower()] = { slot: i, ty: p.ty, }
        }
      }
      let fenv = {
        ..Env::new(
          vars,
          collation=env.collation,
          catalog=env.catalog,
          deferred=env.deferred,
          ansi_nulls=f.ansi_nulls,
          options=env.options,
        ),
        ids: env.ids,
        nest: env.nest + 1,
        table_params,
      }
      let bq = module_binding(env, written, () => bind_query_inner(fenv, query))
      // like views, computed columns keep fComputed (captured: a * 2 is
      // flags 33 through the function)
      let cols = derived_columns(bq, name.base(), q, []).mapi((i, c) => {
        ..c,
        // like a view's, a NULL column is int (query/derived-untyped-null)
        untyped_null: false,
        origin: module_column_origin(bq.columns[i].origin),
      })
      Some((WithParams(bound, bq.plan), cols))
    }
    MultiStatement(cols) => Some((UserTable(f.id, bound), requalify(cols, q)))
    Scalar(_) => None
  }
}

///|
/// Binds the body of a view or inline function used by a query. A binding
/// error inside it is reported, then 4413 naming the module as written
/// (captured: tail/views-binding-errors; nested modules: only the
/// outermost one is named). Emulator errors pass through unchanged.
fn module_binding(
  env : Env,
  written : String,
  bind : () -> BoundQuery raise @types.SqlError,
) -> BoundQuery raise @types.SqlError {
  bind() catch {
    e => {
      let n = e.number()
      if n >= 50100 && n <= 50199 {
        raise e
      }
      if n != 4413 {
        env.deferred.push(e)
      }
      raise err(
        4413,
        "Could not use view or function '\{written}' because of binding errors.",
      )
    }
  }
}
