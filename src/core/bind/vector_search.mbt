///|
/// VECTOR_SEARCH has two exposed namespaces: source columns use the inner
/// table alias; the outer function alias exposes only distance.
fn bind_vector_search(
  env : Env,
  v : @ast.VectorSearch,
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  if !(env.catalog.preview_features)() {
    raise err(156, "Incorrect syntax near the keyword 'TABLE'.", severity=15)
  }
  guard (env.catalog.table)(v.table) is Some(t) else {
    raise err(208, "Invalid object name '\{object_text(v.table)}'.", state=240)
  }
  guard t.columns.search_by(c => c.name.to_lower() == v.column.name.to_lower())
    is Some(column) else {
    raise err(207, "Invalid column name '\{v.column.name}'.", state=20)
  }
  if !(t.columns[column].ty is Vector(_, _)) {
    raise err(
      42226,
      "The column '\{v.column.name}' is not of vector type. Vector search cannot be performed on a non-vector column.",
    )
  }
  let query = bind_expr(env, v.query) catch {
    @types.SqlError(number=4104, ..) as e => {
      env.deferred.push(e)
      env.deferred.push(e)
      raise e
    }
    e => raise e
  }
  let query = if is_untyped_null(query) {
    @ir.Expr::lit(Null, Vector(1, Float32))
  } else {
    query
  }
  if !(query.ty is Vector(_, _)) {
    raise bad_arg_type(query.ty, 3, "vector_distance")
  }
  let top = bind_expr(env, v.top)
  if is_untyped_null(top) || !(top.ty is (TinyInt | SmallInt | Int | BigInt)) {
    raise err(
      1060,
      "The number of rows provided for a TOP or FETCH clauses row count parameter must be an integer.",
      severity=15,
    )
  }
  let metric = v.metric.trim_end(chars=" ").to_owned().to_lower()
  guard (env.catalog.vector_index)(t.scope, t.id, column, metric)
    is Some(index_id) else {
    raise err(
      42227,
      "Cannot find a vector index with metric '\{metric}' on column '\{v.column.name}'.",
    )
  }
  // Keep SQL arithmetic in the expression evaluator: int and bigint TOP_N
  // have different overflow boundaries, before graph allocation is clamped.
  let integer = n => @ir.Expr::lit(@types.Value::Int(n), @types.Int)
  let raw_width = binary(
    env,
    Div,
    binary(env, Mul, top, integer(3)),
    integer(2),
  )
  let width = named(
    "GREATEST",
    [coerce(integer(5), raw_width.ty), raw_width],
    raw_width.ty,
  )
  let raw_expansion = binary(env, Div, width, integer(6))
  let expansion = named(
    "GREATEST",
    [coerce(integer(4), raw_expansion.ty), raw_expansion],
    raw_expansion.ty,
  )
  let columns : Array[ColumnRef] = [
    {
      qualifier: v.alias_.map(a => a.name.to_lower()).unwrap_or(""),
      name: "distance",
      ty: Float,
      nullable: false,
      origin: BaseColumn(identity=false),
      untyped_null: false,
    },
  ]
  columns.append(
    requalify(
      t.columns,
      v.source_alias.map(a => a.name.to_lower()).unwrap_or(t.name.to_lower()),
    ),
  )
  (
    TableFunc(VectorSearch(scope=t.scope, id=t.id, index_id~), [
      query, top, width, expansion,
    ]),
    columns,
  )
}
