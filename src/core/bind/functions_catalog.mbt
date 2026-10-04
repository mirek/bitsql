///|
/// Binder hook for catalog/metadata functions (OBJECT_ID, COL_LENGTH, ...).
/// Bound as `Call(Named("NAME"), args)`; the session evaluates them through
/// `Ctx::ext` because they need the database (exec cannot see it). Result
/// types are captured (corpus catalog/functions): every one is nullable.
fn bind_call_catalog(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let args = call.args
  // trigger functions (session-evaluated): UPDATE(col) takes a column name
  match name {
    "UPDATE" => {
      arity(name, args, 1)
      guard args[0].kind is Column(parts) else {
        raise @types.sql_error(
          102,
          "Incorrect syntax near 'UPDATE'.",
          severity=15,
        )
      }
      let col = parts[parts.length() - 1].name
      return Some(
        bit_expr(
          Call(Named(name), [
            mk(
              Lit(String(col)),
              VarChar(Some(128), @types.default_collation),
              false,
            ),
          ]),
          false,
        ),
      )
    }
    // captured: APPLOCK_MODE nvarchar(32) nullable, APPLOCK_TEST int NOT NULL
    "APPLOCK_MODE" => {
      arity(name, args, 3)
      return Some(
        mk(
          Call(Named(name), applock_args(env, name, args, 2)),
          NVarChar(Some(32), @types.default_collation),
          true,
        ),
      )
    }
    "APPLOCK_TEST" => {
      arity(name, args, 4)
      return Some(
        mk(Call(Named(name), applock_args(env, name, args, 3)), Int, false),
      )
    }
    "TRIGGER_NESTLEVEL" => {
      arity_range(name, args, 0, 3)
      return Some(
        mk(Call(Named(name), args.map(a => bind_expr(env, a))), Int, true),
      )
    }
    _ => ()
  }
  let sysname : @types.SqlType = NVarChar(Some(128), @types.default_collation)
  let ident : @types.SqlType = Numeric(38, 0)
  let (lo, hi, ty) : (Int, Int, @types.SqlType) = match name {
    "OBJECT_ID" => (1, 2, Int)
    "OBJECT_NAME" | "OBJECT_SCHEMA_NAME" => (1, 2, sysname)
    "SCHEMA_ID" => (0, 1, Int)
    "SCHEMA_NAME" => (0, 1, sysname)
    "COL_LENGTH" => (2, 2, SmallInt)
    "COL_NAME" => (2, 2, sysname)
    "COLUMNPROPERTY" | "INDEXPROPERTY" => (3, 3, Int)
    "OBJECTPROPERTY" => (2, 2, Int)
    "TYPE_ID" => (1, 1, Int)
    "TYPE_NAME" => (1, 1, sysname)
    "DB_ID" => (0, 1, SmallInt)
    "IDENT_CURRENT" | "IDENT_SEED" | "IDENT_INCR" => (1, 1, ident)
    "OBJECT_DEFINITION" => (1, 1, NVarChar(None, @types.default_collation))
    "HAS_PERMS_BY_NAME" => (3, 5, Int)
    _ =>
      // schema-qualified calls name user-defined functions (bind/udf.mbt);
      // unqualified ones are built-ins only (195 otherwise, captured)
      if call.name.parts.length() > 1 {
        return Some(bind_scalar_udf(env, call))
      } else {
        return None
      }
  }
  if lo == hi {
    arity(name, args, lo)
  } else {
    arity_range(name, args, lo, hi)
  }
  let bound = args.map(a => bind_expr(env, a))
  Some(mk(Call(Named(name), bound), ty, true))
}

///|
/// APPLOCK_MODE/APPLOCK_TEST arguments: the first `checked` (principal,
/// resource, and APPLOCK_TEST's mode) must be strings; a NULL literal or
/// another type is 8116 at compile time (captured: msduck gaps-applock
/// #058-#061). The owner argument may be NULL (= Transaction).
fn applock_args(
  env : Env,
  name : String,
  args : Array[@ast.Expr],
  checked : Int,
) -> Array[@ir.Expr] raise @types.SqlError {
  let fname = name.to_lower()
  args.mapi((i, a) => {
    let e = bind_expr(env, a)
    if i < checked {
      if is_null_lit(e) {
        raise null_arg(i + 1, fname)
      }
      guard e.ty is (Char(_) | VarChar(_) | NChar(_) | NVarChar(_)) else {
        raise bad_arg_type(e.ty, i + 1, fname)
      }
    }
    e
  })
}
