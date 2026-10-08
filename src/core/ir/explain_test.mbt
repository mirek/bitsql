///|
test "logical explain includes expression subqueries and table names" {
  let sub : @ir.Expr = {
    kind: Subquery(Scan(scope=0, id=2, rowid=false)),
    ty: @types.SqlType::Int,
    nullable: true,
  }
  let plan = @ir.Plan::Project(Scan(scope=0, id=1, rowid=false), [sub])
  let report = @ir.explain_plan(plan, (_, id) => {
    if id == 1 {
      "dbo.orders"
    } else {
      "dbo.items"
    }
  })
  assert_eq(report.schema_version, 1)
  assert_eq(report.kind, "logical")
  assert_true(!report.truncated)
  assert_eq(report.nodes.length(), 3)
  assert_eq(report.nodes[1].detail, "dbo.orders")
  assert_eq(report.nodes[2].detail, "dbo.items")
  assert_eq(report.nodes[1].parent, 0)
  assert_eq(report.nodes[2].parent, 0)
  assert_true(report.text().contains("dbo.orders"))
  assert_true(report.text().contains("dbo.items"))
}

///|
test "logical explain bounds depth and width and reports truncation" {
  let mut plan = @ir.Plan::OneRow
  for _ in 0..<1000 {
    plan = @ir.Plan::Project(plan, [])
  }
  let deep = @ir.explain_plan(plan, (_, _) => "table")
  assert_true(deep.truncated)
  assert_eq(deep.nodes.length(), 65)
  assert_true(deep.text().contains("[plan truncated]"))
  let wide = @ir.explain_plan(
    @ir.Plan::UnionAll(Array::make(1000, @ir.Plan::OneRow)),
    (_, _) => "table",
  )
  assert_true(wide.truncated)
  assert_eq(wide.nodes.length(), 256)
}
