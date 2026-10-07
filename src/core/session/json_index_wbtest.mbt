///|
fn json_index_run(s : Session, sql : String) -> Unit raise {
  for item in s.run_batch(sql, 0) {
    if item is @reply.Message(m) && m.class >= 11 {
      fail(m.message)
    }
  }
}

///|
/// Compare the optimization against a forced scan and observe its source
/// access. SQL behavior itself is covered by oracle maintenance captures.
fn json_index_equivalent(
  s : Session,
  sql : String,
  indexed : Bool,
) -> Unit raise {
  s.frames.push(Frame::new())
  guard @parse.parse_statement(sql).kind is Select(q) else {
    fail("query required")
  }
  let plan = @bind.bind_query(s.env(), q).plan
  let base = s.ctx()
  let expected = @exec.run({ ..base, seek_json: @exec.no_json_seek, }, plan)
  let scans : Array[Bool] = []
  let lookups : Array[Bool] = []
  let ctx : @exec.Ctx = {
    ..base,
    scan_row: (_, _, _) => (),
    source: (scope, id) => {
      scans.push(true)
      (base.source)(scope, id)
    },
    seek_json: (scope, id, column, path) => {
      let found = (base.seek_json)(scope, id, column, path)
      if found is Some(_) {
        lookups.push(true)
      }
      found
    },
  }
  assert_eq(@exec.run(ctx, plan), expected)
  assert_eq(!lookups.is_empty(), indexed)
  assert_eq(scans.is_empty(), indexed)
  s.frames.clear()
}

///|
test "JSON path index tracks mutation, deletion, snapshots and rebuild" {
  let s = Session::new(Server::new(), spid=51, database="master", seed=1)
  json_index_run(
    s, "CREATE TABLE t(id int CONSTRAINT pk PRIMARY KEY,j json); CREATE JSON INDEX ix ON t(j);",
  )
  json_index_run(
    s, "INSERT t VALUES(1,N'{\"a\":[1,2]}'),(2,N'{\"b\":2}'),(3,N'{\"a\":[]}'),(4,NULL);",
  )
  let check = () => {
    json_index_equivalent(
      s, "SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.a[*]')=1 ORDER BY id", true,
    )
    json_index_equivalent(
      s, "SELECT id FROM t WHERE JSON_PATH_EXISTS(j,'$.a')=1 ORDER BY id", true,
    )
    json_index_equivalent(
      s, "SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.b')=1 ORDER BY id", true,
    )
  }
  check()
  json_index_run(
    s, "BEGIN TRAN; UPDATE t SET j.modify('$.a',JSON_QUERY(N'[2]')) WHERE id=2;",
  )
  check()
  json_index_run(
    s, "SAVE TRAN checkpoint1; UPDATE t SET j.modify('$.a',NULL) WHERE id=1; DELETE t WHERE id=2;",
  )
  check()
  json_index_run(s, "ROLLBACK TRAN checkpoint1;")
  check()
  json_index_run(s, "ROLLBACK;")
  check()
  json_index_run(
    s, "ALTER INDEX ix ON t DISABLE; UPDATE t SET j.modify('$.a',JSON_QUERY(N'[2]')) WHERE id=2;",
  )
  json_index_equivalent(
    s, "SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.a[*]')=1 ORDER BY id", false,
  )
  json_index_run(s, "ALTER INDEX ix ON t REBUILD;")
  check()
  json_index_run(s, "TRUNCATE TABLE t;")
  check()
}

///|
test "JSON subset indexes cannot prune uncovered paths and bulk deletes remove postings" {
  let s = Session::new(Server::new(), spid=51, database="master", seed=1)
  json_index_run(
    s, "CREATE TABLE t(id int CONSTRAINT pk PRIMARY KEY,j json); CREATE JSON INDEX ix ON t(j) FOR ('$.a');",
  )
  json_index_run(
    s, "INSERT t SELECT value,CAST(CASE WHEN value%2=0 THEN N'{\"a\":[2]}' ELSE N'{\"b\":2}' END AS json) FROM GENERATE_SERIES(1,160);",
  )
  json_index_equivalent(
    s, "SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.a[*]')=1 ORDER BY id", true,
  )
  json_index_equivalent(
    s, "SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.b')=1 ORDER BY id", false,
  )
  json_index_run(s, "DELETE t WHERE id<=100;")
  json_index_equivalent(
    s, "SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.a[*]')=1 ORDER BY id", true,
  )
  json_index_equivalent(
    s, "SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.b')=1 ORDER BY id", false,
  )
}
