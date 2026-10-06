///|
test "context stamp reader follows table changes and restored databases" {
  let server = Server::new()
  let s = Session::new(server, spid=51, database="master", seed=1)
  let run = (sql : String) => {
    for item in s.run_batch(sql, 0) {
      if item is @reply.Message(m) && m.class >= 11 {
        fail(m.message)
      }
    }
  }
  run("CREATE TABLE a (id int); CREATE TABLE b (id int); INSERT a VALUES (1)")
  let a = s.db_of(0).lookup("dbo", "a").unwrap()
  let b = s.db_of(0).lookup("dbo", "b").unwrap()
  let read = s.stamp_reader()
  let original = read(0, a)
  assert_true(original is Some(_))
  for _ in 0..<10 {
    assert_eq(read(0, a), original)
    assert_eq(read(0, b), s.data_stamp(0, b))
  }
  run("INSERT b VALUES (2)")
  assert_eq(read(0, a), original)
  run("BEGIN TRAN; UPDATE a SET id = 2; SAVE TRAN checkpoint1")
  let changed = read(0, a)
  assert_true(changed != original)
  run("UPDATE a SET id = 3")
  assert_true(read(0, a) != changed)
  run("ROLLBACK TRAN checkpoint1")
  assert_eq(read(0, a), s.data_stamp(0, a))
  run("ROLLBACK")
  assert_eq(read(0, a), s.data_stamp(0, a))
  run("TRUNCATE TABLE a")
  assert_true(read(0, a) != original)
  run("DROP TABLE a")
  assert_eq(read(0, a), None)
  assert_eq(read(2, b), None)
  assert_eq(read(0, -1), None)
  // Switching to another immutable Db with the same table id must miss.
  let saved = s.db_of(0)
  let before = read(0, b)
  server.set_db("other", saved.insert_row(b, 999L, [Int(9)]))
  s.rt.database = "OtHeR"
  assert_true(read(0, b) != before)
  s.rt.database = "master"
  assert_eq(read(0, b), s.data_stamp(0, b))
  // Temp and table-variable scopes resolve independently, even when they
  // temporarily share the very same immutable database object.
  s.temp = saved
  s.tvars = saved
  assert_eq(read(1, b), s.data_stamp(1, b))
  assert_eq(read(3, b), s.data_stamp(3, b))
  s.temp = saved.insert_row(b, 1001L, [Int(11)])
  assert_eq(read(1, b), s.data_stamp(1, b))
  assert_eq(read(3, b), s.data_stamp(3, b))
  assert_eq(read(0, b), s.data_stamp(0, b))
  // Other contexts may observe writes and restoration between our probes.
  // An old cached stamp is still valid only for its original immutable data.
  let restored = read(0, b)
  server.set_db("master", saved.insert_row(b, 1000L, [Int(10)]))
  let other_reader = s.stamp_reader()
  let intermediate = other_reader(0, b)
  assert_true(intermediate != restored)
  server.set_db("master", saved)
  assert_eq(read(0, b), restored)
  assert_eq(other_reader(0, b), s.data_stamp(0, b))
  // Numeric cross-database scopes use the same current-db resolution path.
  run("CREATE DATABASE stamp_other")
  let scope = OTHER_DB_SCOPE + server.database_id("stamp_other").unwrap()
  server.set_db("stamp_other", saved)
  assert_eq(read(scope, b), s.data_stamp(scope, b))
  server.set_db("stamp_other", saved.insert_row(b, 1002L, [Int(12)]))
  assert_eq(read(scope, b), s.data_stamp(scope, b))
  assert_eq(read(0, b), s.data_stamp(0, b))
  // Crossing the bounded cache capacity must preserve every table's stamp.
  for i in 0..<70 {
    run("CREATE TABLE stamp_\{i} (id int)")
  }
  let ids = Array::makei(70, i => {
    s.db_of(0).lookup("dbo", "stamp_\{i}").unwrap()
  })
  for _ in 0..<2 {
    for id in ids {
      assert_eq(read(0, id), s.data_stamp(0, id))
    }
  }
}
