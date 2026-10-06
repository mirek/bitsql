// Native JSON statement mutators. Oracle contracts: sql2025/json-modify-*.

///|
fn Session::bind_var_mutator(
  self : Session,
  name : String,
  meth : String,
  args : Array[@ast.Expr],
) -> (@bind.VarInfo, @ir.Expr) raise {
  guard self.frame().vars.get(name.to_lower()) is Some(info) else {
    raise @types.sql_error(
      137,
      "Must declare the scalar variable \"\{name}\".",
      severity=15,
    )
  }
  let current : @ir.Expr = {
    kind: Var(info.slot),
    ty: info.ty,
    nullable: true,
  }
  (info, @bind.bind_json_mutator(self.env(), current, meth, args, name))
}

///|
fn duplicate_mutator_column(name : String) -> @types.SqlError {
  @types.sql_error(
    264,
    "The column name '\{name}' is specified more than once in the SET clause or column list of an INSERT. A column cannot be assigned more than one value in the same clause. Modify the clause to make sure that a column is updated only once. If this statement updates or inserts columns into a view, column aliasing can conceal the duplication in your code.",
  )
}
