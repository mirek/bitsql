///|
fn profile_test_ctx(indexed : Bool) -> Ctx {
  let rows : Array[(Int64, Row)] = Array::makei(100, i => {
    (i.to_int64(), [@types.Value::Int(i)])
  })
  {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    source: (_, _) => rows,
    scan_row: (_, _, _) => (),
    ext: (_, _) => None,
    user_fn: no_user_fn,
    user_table: no_user_table,
    seek: (_, _, key) => {
      if indexed {
        Some(rows.filter(kv => kv.1[0] == key[0].1))
      } else {
        None
      }
    },
    seek_json: no_json_seek,
    vector_search: no_vector_search,
    profile: None,
    stamp: no_stamp,
  }
}

///|
fn profile_lookup_plan() -> @ir.Plan {
  let predicate : @ir.Expr = {
    kind: Cmp(
      Eq,
      { kind: Col(0), ty: Int, nullable: false, },
      @ir.Expr::lit(Int(42), Int),
      None,
    ),
    ty: Bit,
    nullable: false,
  }
  Filter(Scan(scope=0, id=1, rowid=false), predicate)
}

///|
test "profiling preserves a seek fast path and exposes reduced source access" {
  let plan = profile_lookup_plan()
  let scan_profile = QueryProfile::new()
  let seek_profile = QueryProfile::new()
  let scan = profile_test_ctx(false)
  let seek = profile_test_ctx(true)
  let expected = run(profile_test_ctx(false), plan)
  assert_eq(run(scan_profile.wrap(scan), plan), expected)
  assert_eq(run(seek_profile.wrap(seek), plan), expected)
  assert_eq(seek_profile.seek_hits, 1L)
  assert_eq(seek_profile.seek_candidates, 1L)
  assert_eq(scan_profile.seek_hits, 0L)
  assert_true(scan_profile.source_rows > seek_profile.source_rows)
  assert_eq(seek_profile.source_rows, 0L)
  let ordinary = profile_test_ctx(true)
  ignore(run(ordinary, plan))
  assert_eq(ordinary.rt.work_done, seek.rt.work_done)
}

///|
test "profiling preserves streamed partial rows and suspension" {
  let base = profile_test_ctx(false)
  let ctx = {
    ..base,
    scan_row: (_, _, row) => if row == 3L { raise @types.Suspend },
  }
  let profile = QueryProfile::new()
  let ordinary : Array[Row] = []
  let observed : Array[Row] = []
  let plan = @ir.Plan::Scan(scope=0, id=1, rowid=false)
  for (c, out) in [(ctx, ordinary), (profile.wrap(ctx), observed)] {
    let suspended = try {
      stream(c, plan, row => out.push(row))
      false
    } catch {
      @types.Suspend => true
      e => raise e
    }
    assert_true(suspended)
  }
  assert_eq(observed, ordinary)
  assert_eq(observed.length(), 3)
  assert_eq(profile.scan_rows, 3L)
}

///|
test "ordinary execution does not update an unrelated profile" {
  let profile = QueryProfile::new()
  ignore(run(profile_test_ctx(false), profile_lookup_plan()))
  assert_eq(profile.source_calls, 0L)
  assert_eq(profile.seek_attempts, 0L)
  assert_eq(profile.scan_rows, 0L)
}

///|
test "physical observations have bounded retention" {
  let p = QueryProfile::new()
  for i in 0..<1000 {
    p.record("full_sort", i, 0)
  }
  assert_eq(p.events.length(), 128)
  assert_true(p.events_truncated)
}
