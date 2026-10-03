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
      // schema-qualified calls name user-defined functions, which are
      // registered (CREATE FUNCTION) but not executed yet
      if call.name.parts.length() > 1 {
        raise @types.not_supported("calling user-defined functions")
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
