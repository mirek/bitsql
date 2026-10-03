///|
fn batches(script : String) -> String {
  @lex.split_go_batches(script)
  .map(b => "<" + b.replace_all(old="\r", new="\\r") + ">")
  .join("|")
}

///|
test "split on GO lines" {
  inspect(
    batches("SELECT 1\nGO\nSELECT 2\n"),
    content=(
      #|<SELECT 1
      #|>|<SELECT 2
      #|>
    ),
  )
  inspect(
    batches("SELECT 1\r\ngo\r\nSELECT 2"),
    content=(
      #|<SELECT 1\r
      #|>|<SELECT 2>
    ),
  )
  inspect(
    batches("  Go  \nSELECT 1\n  GO -- done\n"),
    content=(
      #|<SELECT 1
      #|>
    ),
  )
  inspect(
    batches("SELECT 1\nGO 3\nSELECT 2"),
    content=(
      #|<SELECT 1
      #|>|<SELECT 1
      #|>|<SELECT 1
      #|>|<SELECT 2>
    ),
  )
  inspect(batches("GO\nGO\n\nGO"), content="")
  inspect(
    batches("SELECT 1\nGO"),
    content=(
      #|<SELECT 1
      #|>
    ),
  )
}

///|
test "GO that is not a separator" {
  inspect(
    batches("SELECT 1 GO\nSELECT 2"),
    content=(
      #|<SELECT 1 GO
      #|SELECT 2>
    ),
  )
  inspect(
    batches("SELECT 'a\nGO\nb'\nGO\nSELECT 2"),
    content=(
      #|<SELECT 'a
      #|GO
      #|b'
      #|>|<SELECT 2>
    ),
  )
  inspect(
    batches("/* x\nGO\n*/ SELECT 1"),
    content=(
      #|</* x
      #|GO
      #|*/ SELECT 1>
    ),
  )
  inspect(
    batches("/* a /* b */\nGO\n*/ SELECT 1"),
    content=(
      #|</* a /* b */
      #|GO
      #|*/ SELECT 1>
    ),
  )
  inspect(
    batches("SELECT [a\nGO\n] FROM t"),
    content=(
      #|<SELECT [a
      #|GO
      #|] FROM t>
    ),
  )
  inspect(
    batches("-- GO\nSELECT 1"),
    content=(
      #|<-- GO
      #|SELECT 1>
    ),
  )
  inspect(
    batches("GOTO x\nGO2\nGOx"),
    content=(
      #|<GOTO x
      #|GO2
      #|GOx>
    ),
  )
  inspect(
    batches("SELECT 'it''s'\nGO\nSELECT 2"),
    content=(
      #|<SELECT 'it''s'
      #|>|<SELECT 2>
    ),
  )
}
