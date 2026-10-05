///|
test "top_n_prepared equals the first n rows of the stable sort" {
  let mk = (e : @ir.ExprKind, desc : Bool) => @ir.SortKey::{
    expr: { kind: e, ty: Int, nullable: true, },
    desc,
    collation: None,
  }
  for desc in [false, true] {
    let keys = [mk(Col(0), desc), mk(Col(1), false)]
    let ansi = [false, false]
    // periodic keys with many ties and NULLs; payload = input position
    let rows : Array[(Array[@types.SortKey], Int)] = Array::makei(500, i => {
      let a : @types.Value = if i % 7 == 0 { Null } else { Int(i * 37 % 11) }
      let b : @types.Value = Int(i % 3)
      ([@types.sort_key(a), @types.sort_key(b)], i)
    })
    let sorted = rows.copy()
    sort_prepared(sorted, keys, ansi)
    for n in [0, 1, 2, 5, 17, 100, 499, 500] {
      let expect = sorted[0:n].iter().map(p => p.1).to_array()
      assert_eq(top_n_prepared(rows, n, keys, ansi), expect)
    }
  }
}
