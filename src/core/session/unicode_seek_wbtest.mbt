///|
test "Unicode widening uses real index seeks with scan-equivalent results" {
  let s = Session::new(Server::new(), spid=51, database="master", seed=1)
  json_index_run(
    s, "CREATE TABLE foo(id int PRIMARY KEY,note nvarchar(50)); CREATE INDEX ix ON foo(note); INSERT foo VALUES(1,N'note');",
  )
  s.frames.push(Frame::new())
  for
    sql in [
      "SELECT COUNT(*) FROM foo WITH(INDEX(ix)) WHERE note=N'note'", "SELECT id FROM foo WHERE note=CAST(N'note' AS nvarchar(4000))",
      "SELECT id FROM foo WHERE note=N'not found'",
    ] {
    guard @parse.parse_statement(sql).kind is Select(q) else { fail("query") }
    let plan = @bind.bind_query(s.env(), q).plan
    let base = s.ctx()
    let expected = @exec.run({ ..base, seek: @exec.no_seek, }, plan)
    let profile = @exec.QueryProfile::new()
    assert_eq(@exec.run(profile.wrap(base), plan), expected)
    guard profile.counters() is Json::Object(counters) else { fail("counters") }
    assert_eq(counters["seek_hits"], Json::string("1"))
    assert_eq(counters["source_calls"], Json::string("0"))
  }
}
