///|
test "insert forms" {
  inspect(
    sx("INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y')"),
    content=(
      #|(insert (table t) (a b) (values (1 'x') (2 'y')))
    ),
  )
  inspect(
    sx("INSERT t DEFAULT VALUES"),
    content=(
      #|(insert (table t) default-values)
    ),
  )
  inspect(
    sx("INSERT INTO t SELECT * FROM s"),
    content=(
      #|(insert (table t) (select * (from (table s))))
    ),
  )
  inspect(
    sx("INSERT INTO t (a) SELECT a FROM s UNION SELECT 1"),
    content=(
      #|(insert (table t) (a) (union (select a (from (table s))) (select 1)))
    ),
  )
  inspect(
    sx("INSERT INTO t (a) (SELECT a FROM s)"),
    content=(
      #|(insert (table t) (a) (nested (select a (from (table s)))))
    ),
  )
  inspect(
    sx("INSERT INTO t VALUES (DEFAULT, NULL, -1)"),
    content=(
      #|(insert (table t) (values (DEFAULT NULL (- 1))))
    ),
  )
  inspect(
    sx("INSERT INTO #t EXEC dbo.p @a = 1"),
    content=(
      #|(insert (table #t) (exec dbo.p (arg @a 1)))
    ),
  )
  inspect(
    sx("INSERT INTO @items (name) VALUES (N'a')"),
    content=(
      #|(insert (table @items) (name) (values (N'a')))
    ),
  )
  inspect(
    sx("INSERT INTO t WITH (TABLOCK) (a) VALUES (1)"),
    content=(
      #|(insert (table t (with TABLOCK)) (a) (values (1)))
    ),
  )
  inspect(
    sx("INSERT TOP (5) INTO t SELECT a FROM s"),
    content=(
      #|(insert (top 5) (table t) (select a (from (table s))))
    ),
  )
}

///|
test "output clause" {
  inspect(
    sx("INSERT INTO t (a) OUTPUT inserted.id, inserted.a AS added VALUES (1)"),
    content=(
      #|(insert (table t) (a) (output inserted.id (as inserted.a added)) (values (1)))
    ),
  )
  inspect(
    sx("DELETE FROM t OUTPUT deleted.* WHERE id = 1"),
    content=(
      #|(delete (table t) (output deleted.*) (where (= id 1)))
    ),
  )
  inspect(
    sx(
      "UPDATE t SET a = 1 OUTPUT deleted.a, inserted.a INTO log (old_a, new_a) WHERE id = 1",
    ),
    content=(
      #|(update (table t) (set (= a 1)) (output deleted.a inserted.a (into (table log) (old_a new_a))) (where (= id 1)))
    ),
  )
  inspect(
    sx(
      "INSERT INTO t (a) OUTPUT inserted.id INTO @ids OUTPUT inserted.a SELECT a FROM s",
    ),
    content=(
      #|(insert (table t) (a) (output inserted.id (into (table @ids))) (output inserted.a) (select a (from (table s))))
    ),
  )
}

///|
test "update forms" {
  inspect(
    sx("UPDATE t SET a = 1, b += 2, c = DEFAULT WHERE id = 3"),
    content=(
      #|(update (table t) (set (= a 1) (+= b 2) (= c DEFAULT)) (where (= id 3)))
    ),
  )
  inspect(
    sx("UPDATE t SET @x = a = a + 1, @y = b, t.c = NULL"),
    content=(
      #|(update (table t) (set (= @x=a (+ a 1)) (= @y b) (= t.c NULL)))
    ),
  )
  inspect(
    sx("UPDATE TOP (2) t SET a = 1"),
    content=(
      #|(update (top 2) (table t) (set (= a 1)))
    ),
  )
  inspect(
    sx(
      "UPDATE a SET a.v = b.v FROM dbo.t AS a INNER JOIN s AS b ON a.id = b.id WHERE b.x > 0",
    ),
    content=(
      #|(update (table a) (set (= a.v b.v)) (from (join (table dbo.t (as a)) (table s (as b)) (on (= a.id b.id)))) (where (> b.x 0)))
    ),
  )
  inspect(
    sx(
      "UPDATE t WITH (UPDLOCK) SET a -= 1, b *= 2, c /= 3, d %= 4, e &= 5, f |= 6, g ^= 7",
    ),
    content=(
      #|(update (table t (with UPDLOCK)) (set (-= a 1) (*= b 2) (/= c 3) (%= d 4) (&= e 5) (|= f 6) (^= g 7)))
    ),
  )
  inspect(
    sx("UPDATE @items SET qty = 2 WHERE name = N'a'"),
    content=(
      #|(update (table @items) (set (= qty 2)) (where (= name N'a')))
    ),
  )
  inspect(
    sx("UPDATE t SET a = 1 WHERE CURRENT OF c"),
    content=(
      #|(update (table t) (set (= a 1)) (current-of c))
    ),
  )
  inspect(
    sx("UPDATE TOP 2 t SET a = 1"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '2'.
    ),
  )
}

///|
test "delete and truncate" {
  inspect(
    sx("DELETE FROM t WHERE id = 1"),
    content=(
      #|(delete (table t) (where (= id 1)))
    ),
  )
  inspect(
    sx("DELETE t"),
    content=(
      #|(delete (table t))
    ),
  )
  inspect(
    sx("DELETE TOP (2) FROM t"),
    content=(
      #|(delete (top 2) (table t))
    ),
  )
  inspect(
    sx("DELETE a FROM t AS a JOIN s ON s.id = a.id"),
    content=(
      #|(delete (table a) (from (join (table t (as a)) (table s) (on (= s.id a.id)))))
    ),
  )
  inspect(
    sx("DELETE FROM t FROM t JOIN s ON s.id = t.id"),
    content=(
      #|(delete (table t) (from (join (table t) (table s) (on (= s.id t.id)))))
    ),
  )
  inspect(
    sx("DELETE FROM @items WHERE qty = 0"),
    content=(
      #|(delete (table @items) (where (= qty 0)))
    ),
  )
  inspect(
    sx("TRUNCATE TABLE dbo.t"),
    content=(
      #|(truncate dbo.t)
    ),
  )
}

///|
test "merge" {
  inspect(
    sx(
      (
        #|MERGE INTO dbo.target AS t
        #|USING dbo.source AS s
        #|ON t.id = s.id
        #|WHEN MATCHED AND s.qty = 0 THEN DELETE
        #|WHEN MATCHED THEN UPDATE SET t.qty = s.qty, name = s.name
        #|WHEN NOT MATCHED BY TARGET THEN INSERT (id, qty) VALUES (s.id, s.qty)
        #|WHEN NOT MATCHED BY SOURCE THEN DELETE;
      ),
    ),
    content=(
      #|(merge (table dbo.target (as t)) (using (table dbo.source (as s))) (on (= t.id s.id)) (when-matched (and (= s.qty 0)) delete) (when-matched (set (= t.qty s.qty) (= name s.name))) (when-not-matched (insert (id qty) (s.id s.qty))) (when-not-matched-by-source delete))
    ),
  )
  inspect(
    sx(
      (
        #|MERGE t WITH (HOLDLOCK)
        #|USING (VALUES (1, N'a'), (2, N'b')) AS s (id, name)
        #|ON t.id = s.id
        #|WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.name);
      ),
    ),
    content=(
      #|(merge (table t (with HOLDLOCK)) (using (values (1 N'a') (2 N'b') (as s id name))) (on (= t.id s.id)) (when-not-matched (insert (s.id s.name))))
    ),
  )
  inspect(
    sx(
      (
        #|MERGE target AS t
        #|USING (SELECT id, total FROM staging) AS s (sid, amount)
        #|ON t.id = s.sid
        #|WHEN MATCHED THEN UPDATE SET amount = s.amount
        #|WHEN NOT MATCHED THEN INSERT DEFAULT VALUES;
      ),
    ),
    content=(
      #|(merge (table target (as t)) (using (derived (select id total (from (table staging))) (as s sid amount))) (on (= t.id s.sid)) (when-matched (set (= amount s.amount))) (when-not-matched (insert default-values)))
    ),
  )
  inspect(
    sx(
      (
        #|MERGE t USING s ON t.id = s.id
        #|WHEN MATCHED THEN UPDATE SET v = s.v
        #|OUTPUT $action, inserted.id, deleted.v AS old INTO log (act, id, old);
      ),
    ),
    content=(
      #|(merge (table t) (using (table s)) (on (= t.id s.id)) (when-matched (set (= v s.v))) (output $action inserted.id (as deleted.v old) (into (table log) (act id old))))
    ),
  )
  inspect(
    sx("MERGE t USING s ON t.id = s.id WHEN MATCHED THEN DELETE"),
    content=(
      #|Msg 10713, Level 15, State 1, Line 1: A MERGE statement must be terminated by a semi-colon (;).
    ),
  )
  inspect(
    sx("MERGE t USING s ON t.id = s.id;"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near ';'.
    ),
  )
  inspect(
    sx("MERGE t USING s ON t.id = s.id WHEN NOT MATCHED THEN DELETE;"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'DELETE'.
    ),
  )
  inspect(
    sx(
      "MERGE t USING (VALUES (1, 2)) AS s (a) ON t.a = s.a WHEN MATCHED THEN DELETE;",
    ),
    content=(
      #|(merge (table t) (using (values (1 2) (as s a))) (on (= t.a s.a)) (when-matched delete))
    ),
  )
}
