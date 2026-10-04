///|
/// Identity and permission functions (captured as the `sa` login sees them:
/// corpus misc/security-functions). Bound as `Call(Named(..))` and evaluated
/// by the session (login, host and application names come from LOGIN7).
fn bind_call_security(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let sysname : @types.SqlType = NVarChar(Some(128), @types.default_collation)
  let (lo, hi, ty) : (Int, Int, @types.SqlType) = match name {
    "USER_NAME" => (0, 1, sysname)
    "USER_ID" => (0, 1, SmallInt)
    "SUSER_NAME" | "SUSER_SNAME" => (0, 1, sysname)
    "SUSER_ID" => (0, 1, Int)
    "SUSER_SID" => (0, 2, VarBinary(Some(85)))
    "CURRENT_USER" | "SESSION_USER" | "USER" | "SYSTEM_USER" => (0, 0, sysname)
    "ORIGINAL_LOGIN" => (0, 0, NVarChar(Some(4000), @types.default_collation))
    "APP_NAME" => (0, 0, sysname)
    "HOST_NAME" => (0, 0, sysname)
    "HOST_ID" => (0, 0, Char(10, @types.default_collation))
    "IS_SRVROLEMEMBER" => (1, 2, Int)
    "IS_MEMBER" => (1, 1, Int)
    "IS_ROLEMEMBER" => (1, 2, Int)
    "HAS_DBACCESS" => (1, 1, Int)
    "DATABASE_PRINCIPAL_ID" => (0, 1, Int)
    "PERMISSIONS" => (0, 2, Int)
    "CONTEXT_INFO" => (0, 0, VarBinary(Some(128)))
    "MIN_ACTIVE_ROWVERSION" => (0, 0, VarBinary(Some(8)))
    _ => return None
  }
  if lo == hi {
    arity(name, call.args, lo)
  } else {
    arity_range(name, call.args, lo, hi)
  }
  let bound = call.args.map(a => bind_expr(env, a))
  // captured: MIN_ACTIVE_ROWVERSION() is NOT NULL (flags 32, msduck
  // gaps-rowversion_identity #072)
  Some(mk(Call(Named(name), bound), ty, name != "MIN_ACTIVE_ROWVERSION"))
}
