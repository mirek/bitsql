///|
/// exec/named_pure.mbt skips this session's function chain for the names it
/// lists; that is only sound while the chain answers none of them.
test "the session function chain answers no executor-only named built-in" {
  let s = Session::new(Server::new(), spid=51, database="master", seed=1)
  let shapes : Array[Array[@types.Value]] = [
    [],
    [Int(1)],
    [String("x")],
    [String("x"), String("y")],
    [Int(1), Int(2), Int(3)],
    [Null, Null],
  ]
  for name in @exec.pure_named_functions() {
    for args in shapes {
      let answered = try
        s.property_fn(name, args) is Some(_) ||
        s.catalog_fn(name, args) is Some(_)
      catch {
        _ => true
      }
      if answered {
        fail("\{name} is answered by the session chain")
      }
    }
  }
}
