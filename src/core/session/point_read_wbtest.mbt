///|
/// The point read of `harness/bench/compare.mjs` as tedious sends it: an
/// sp_executesql RPC with one int parameter, measured with the reply render
/// the engine does (`moon bench -p mirek/bitsql/core/session -f
/// point_read_wbtest.mbt`). Monitoring is on, as in the host.
fn point_read_session() -> (Session, @tds.RpcCall) raise {
  let server = Server::new()
  server.create_database("bench")
  server.enable_monitoring(638000000000000000L, 2, 1024L)
  let s = Session::new(server, spid=51, database="bench", seed=1)
  let setup = "CREATE TABLE customers (id int IDENTITY PRIMARY KEY, email nvarchar(200) NOT NULL UNIQUE, name nvarchar(100), balance decimal(12, 2) NOT NULL DEFAULT 0, created datetime2 NOT NULL DEFAULT SYSUTCDATETIME()); INSERT customers (email, name) SELECT CONCAT(N'user', g.value, N'@example.com'), CONCAT(N'User ', g.value) FROM GENERATE_SERIES(1, 1000) g"
  // statement boundaries park for samples, as with the engine
  let mut now = 638000000000000000L
  let mut items = s.run_batch(setup, now)
  while s.is_parked() {
    now += 1L
    s.sample(now, 0L)
    items = s.run_batch(setup, now)
  }
  for item in items {
    if item is @reply.Message(m) && m.class >= 11 {
      fail(m.message)
    }
  }
  if s.needs_sample() {
    s.sample(now + 1L, 0L)
  }
  let coll = b"\x09\x04\xd0\x00\x34"
  let text = "SELECT id, email, name, balance FROM customers WHERE id = @id"
  let decls = "@id int"
  let call : @tds.RpcCall = {
    proc: Id(10),
    option_flags: 0,
    params: [
      {
        name: "@statement",
        by_ref: false,
        default_value: false,
        type_info: NVarChar(text.length() * 2, coll),
        value: Text(text),
        tvp: None,
      },
      {
        name: "@params",
        by_ref: false,
        default_value: false,
        type_info: NVarChar(decls.length() * 2, coll),
        value: Text(decls),
        tvp: None,
      },
      {
        name: "@id",
        by_ref: false,
        default_value: false,
        type_info: IntN(4),
        value: Int(7L),
        tvp: None,
      },
    ],
  }
  (s, call)
}

///|
/// One request as the engine runs it: the RPC, its end sample, the render.
fn point_read_once(
  s : Session,
  call : @tds.RpcCall,
  now : Int64,
) -> Bytes raise {
  let items = s.run_rpc(call, now)
  if s.needs_sample() {
    s.sample(now + 1L, 0L)
  }
  @reply.render(Rpc, items, "bitsql")
}

///|
test "point read returns its row" {
  let (s, call) = point_read_session()
  let first = point_read_once(s, call, 638000000000000010L)
  let again = point_read_once(s, call, 638000000000000020L)
  assert_eq(first, again)
  assert_true(first.length() > 100)
}

///|
test "point read" (b : @bench.T) {
  let (s, call) = point_read_session() catch { e => abort(e.to_string()) }
  let mut now = 638000000000000100L
  b.bench(() => {
    now += 10L
    b.keep(point_read_once(s, call, now) catch { e => abort(e.to_string()) })
  })
}

///|
test "point read reply has one row and no error" {
  let (s, call) = point_read_session()
  let items = s.run_rpc(call, 638000000000000010L)
  let rows = items.filter(i => i is Row(_)).length()
  let errors = items.filter(i => {
    i is @reply.Message({ class, .. }) && class >= 11
  })
  assert_eq(rows, 1)
  assert_eq(errors.length(), 0)
}
