///|
/// Parses `sql`, returning an error number or 0; must never panic.
fn outcome(sql : String) -> Int {
  try @parse.parse_batch(sql) catch {
    e => e.number()
  } noraise {
    _ => 0
  }
}

///|
test "every prefix of every test query parses or errors cleanly" {
  let mut checked = 0
  let numbers : Map[Int, Bool] = Map([])
  for q in corpus {
    for i in 0..<=q.length() {
      let n = outcome(q.view(end_offset=i).to_owned())
      numbers[n] = true
      checked += 1
    }
    // Also every suffix, which starts mid-token.
    for i in 0..<q.length() {
      let n = outcome(q.view(start_offset=i).to_owned())
      numbers[n] = true
      checked += 1
    }
  }
  assert_true(checked > 10000)
  let seen = numbers.keys().collect()
  seen.sort()
  debug_inspect(
    seen,
    content=(
      #|[0, 102, 105, 111, 113, 156, 159, 319, 10713]
    ),
  )
}

///|
test "large migration parses in one go" {
  let unit =
    #|CREATE TABLE dbo.t (id INT IDENTITY(1,1) PRIMARY KEY, name NVARCHAR(100) NOT NULL DEFAULT N'', created DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME());
    #|INSERT INTO dbo.t (name) VALUES (N'a'), (N'b'), (N'c');
    #|UPDATE dbo.t SET name = UPPER(name) WHERE id IN (SELECT id FROM dbo.t WHERE name LIKE N'a%');
    #|IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix') CREATE INDEX ix ON dbo.t (name) INCLUDE (created);
    #|DROP TABLE dbo.t;
    #|
  let script = unit.repeat(2000)
  let ss = @parse.parse_batch(script) catch { _ => [] }
  inspect(
    ss.length(),
    content=(
      #|10000
    ),
  )
  inspect(
    ss[ss.length() - 1].span.line,
    content=(
      #|10000
    ),
  )
}
