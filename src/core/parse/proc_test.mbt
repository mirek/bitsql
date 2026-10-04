///|
test "tedious login SET batch" {
  inspect(
    sx(
      (
        #|set textsize 2147483647
        #|set quoted_identifier on
        #|set arithabort off
        #|set numeric_roundabort off
        #|set ansi_warnings on
        #|set ansi_padding on
        #|set ansi_nulls on
        #|set concat_null_yields_null on
        #|set cursor_close_on_commit off
        #|set implicit_transactions off
        #|set language us_english
        #|set dateformat mdy
        #|set datefirst 7
        #|set transaction isolation level read committed
      ),
    ),
    content=(
      #|(set-option (TEXTSIZE) 2147483647)
      #|(set-option (QUOTED_IDENTIFIER) ON)
      #|(set-option (ARITHABORT) OFF)
      #|(set-option (NUMERIC_ROUNDABORT) OFF)
      #|(set-option (ANSI_WARNINGS) ON)
      #|(set-option (ANSI_PADDING) ON)
      #|(set-option (ANSI_NULLS) ON)
      #|(set-option (CONCAT_NULL_YIELDS_NULL) ON)
      #|(set-option (CURSOR_CLOSE_ON_COMMIT) OFF)
      #|(set-option (IMPLICIT_TRANSACTIONS) OFF)
      #|(set-option (LANGUAGE) us_english)
      #|(set-option (DATEFORMAT) mdy)
      #|(set-option (DATEFIRST) 7)
      #|(set-isolation 'READ COMMITTED')
    ),
  )
}

///|
test "declare and set" {
  inspect(
    sx("DECLARE @x INT = 1, @s NVARCHAR(50), @d AS decimal(10, 2)"),
    content=(
      #|(declare (@x INT 1) (@s NVARCHAR(50)) (@d decimal(10,2)))
    ),
  )
  inspect(
    sx("SET @x = @x + 1"),
    content=(
      #|(set @x = (+ @x 1))
    ),
  )
  inspect(
    sx("SET @x += 1 SET @s ^= 2"),
    content=(
      #|(set @x += 1)
      #|(set @s ^= 2)
    ),
  )
  inspect(
    sx("SET NOCOUNT ON"),
    content=(
      #|(set-option (NOCOUNT) ON)
    ),
  )
  inspect(
    sx("SET ANSI_NULLS, ANSI_WARNINGS ON"),
    content=(
      #|(set-option (ANSI_NULLS ANSI_WARNINGS) ON)
    ),
  )
  inspect(
    sx("SET XACT_ABORT ON; SET NOCOUNT OFF"),
    content=(
      #|(set-option (XACT_ABORT) ON)
      #|(set-option (NOCOUNT) OFF)
    ),
  )
  inspect(
    sx("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"),
    content=(
      #|(set-isolation 'SERIALIZABLE')
    ),
  )
  inspect(
    sx("SET TRANSACTION ISOLATION LEVEL SNAPSHOT"),
    content=(
      #|(set-isolation 'SNAPSHOT')
    ),
  )
  inspect(
    sx("SET IDENTITY_INSERT archive.events ON"),
    content=(
      #|(set-identity-insert archive.events ON)
    ),
  )
  inspect(
    sx("SET LANGUAGE N'us_english'"),
    content=(
      #|(set-option (LANGUAGE) N'us_english')
    ),
  )
  inspect(
    sx("SET DEADLOCK_PRIORITY LOW SET LOCK_TIMEOUT -1 SET ROWCOUNT @n"),
    content=(
      #|(set-option (DEADLOCK_PRIORITY) LOW)
      #|(set-option (LOCK_TIMEOUT) (- 1))
      #|(set-option (ROWCOUNT) @n)
    ),
  )
  inspect(
    sx("SET STATISTICS IO, TIME ON"),
    content=(
      #|(set-option (STATISTICS IO STATISTICS TIME) ON)
    ),
  )
  inspect(
    sx("SET CONTEXT_INFO 0x01"),
    content=(
      #|(set-option (CONTEXT_INFO) 0x01)
    ),
  )
  inspect(
    sx(
      (
        #|DECLARE @items TABLE (
        #|  id INT IDENTITY(1,1) PRIMARY KEY,
        #|  name NVARCHAR(50) NOT NULL,
        #|  qty INT DEFAULT 1,
        #|  UNIQUE (name),
        #|  CHECK (qty >= 0)
        #|)
      ),
    ),
    content=(
      #|(declare-table @items (column id INT (identity 1 1) (primary-key)) (column name NVARCHAR(50) not-null) (column qty INT (default 1)) (unique (name)) (check (>= qty 0)))
    ),
  )
  inspect(
    sx("DECLARE @t TABLE (id INT), @x INT"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near ','.
    ),
  )
  inspect(
    sx("DECLARE @x INT, @t TABLE (id INT)"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'TABLE'.
    ),
  )
  inspect(
    sx("DECLARE @c CURSOR"),
    content=(
      #|(declare (@c CURSOR))
    ),
  )
}

///|
test "control flow" {
  inspect(
    sx("IF @x > 0 SELECT 'pos' ELSE SELECT 'neg'"),
    content=(
      #|(if (> @x 0) (select 'pos') (else (select 'neg')))
    ),
  )
  inspect(
    sx("IF @x > 0 PRINT 'a'; ELSE PRINT 'b';"),
    content=(
      #|(if (> @x 0) (print 'a') (else (print 'b')))
    ),
  )
  inspect(
    sx("IF NOT EXISTS (SELECT 1 FROM t) BEGIN INSERT t DEFAULT VALUES END"),
    content=(
      #|(if (not (exists (select 1 (from (table t))))) (block (insert (table t) default-values)))
    ),
  )
  inspect(
    sx("IF (@a = 1) IF @b = 2 PRINT 1 ELSE PRINT 2"),
    content=(
      #|(if (paren (= @a 1)) (if (= @b 2) (print 1) (else (print 2))))
    ),
  )
  inspect(
    sx("IF OBJECT_ID('dbo.t', 'U') IS NOT NULL DROP TABLE dbo.t"),
    content=(
      #|(if (is-not-null (call OBJECT_ID 'dbo.t' 'U')) (drop-table dbo.t))
    ),
  )
  inspect(
    sx("WHILE @i < 10 BEGIN SET @i = @i + 1; IF @i = 5 BREAK; CONTINUE END"),
    content=(
      #|(while (< @i 10) (block (set @i = (+ @i 1)) (if (= @i 5) (break)) (continue)))
    ),
  )
  inspect(
    sx("BEGIN END"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'END'.
    ),
  )
  inspect(
    sx("RETURN"),
    content=(
      #|(return)
    ),
  )
  inspect(
    sx("RETURN 0"),
    content=(
      #|(return 0)
    ),
  )
  inspect(
    sx("RETURN (SELECT 1)"),
    content=(
      #|(return (subquery (select 1)))
    ),
  )
  inspect(
    sx("IF 1 = 1 RETURN SELECT 1"),
    content=(
      #|(if (= 1 1) (return))
      #|(select 1)
    ),
  )
  inspect(
    sx("lbl: PRINT 1 GOTO lbl"),
    content=(
      #|(label lbl)
      #|(print 1)
      #|(goto lbl)
    ),
  )
  inspect(
    sx("WAITFOR DELAY '00:00:01'"),
    content=(
      #|(waitfor DELAY '00:00:01')
    ),
  )
}

///|
test "try catch throw raiserror" {
  inspect(
    sx(
      (
        #|BEGIN TRY
        #|  INSERT INTO t VALUES (1);
        #|  SELECT 1
        #|END TRY
        #|BEGIN CATCH
        #|  IF @@TRANCOUNT > 0 ROLLBACK;
        #|  SELECT ERROR_NUMBER() AS n, ERROR_LINE() AS l;
        #|  THROW;
        #|END CATCH
      ),
    ),
    content=(
      #|(try (insert (table t) (values (1))) (select 1) (catch (if (> @@TRANCOUNT 0) (rollback)) (select (as (call ERROR_NUMBER) n) (as (call ERROR_LINE) l)) (throw)))
    ),
  )
  inspect(
    sx("BEGIN TRY SELECT 1 END TRY BEGIN CATCH END CATCH"),
    content=(
      #|(try (select 1) (catch))
    ),
  )
  inspect(
    sx("RAISERROR ('oops %s', 16, 1, 'x') WITH NOWAIT"),
    content=(
      #|(raiserror 'oops %s' 16 1 'x' NOWAIT)
    ),
  )
  inspect(
    sx("RAISERROR (@msg, 16, 1) WITH LOG, SETERROR"),
    content=(
      #|(raiserror @msg 16 1 LOG SETERROR)
    ),
  )
  inspect(
    sx("THROW"),
    content=(
      #|(throw)
    ),
  )
  inspect(
    sx("THROW 50000, 'err', 1"),
    content=(
      #|(throw 50000 'err' 1)
    ),
  )
  inspect(
    sx("THROW 50000, @msg, 1;"),
    content=(
      #|(throw 50000 @msg 1)
    ),
  )
  inspect(
    sx("PRINT 'x'\nTHROW 50000, 'err', 1"),
    content=(
      #|Msg 102, Level 15, State 1, Line 2: Incorrect syntax near 'THROW'.
    ),
  )
  inspect(
    sx("PRINT 'x';\nTHROW 50000, 'err', 1"),
    content=(
      #|(print 'x')
      #|(throw 50000 'err' 1)
    ),
  )
  inspect(
    sx("SELECT 1 THROW 50000, 'err', 1"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '50000'.
    ),
  )
  inspect(
    sx("BEGIN CATCH THROW; END CATCH"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'CATCH'.
    ),
  )
}

///|
test "transactions" {
  inspect(
    sx("BEGIN TRANSACTION"),
    content=(
      #|(begin-tran)
    ),
  )
  inspect(
    sx("BEGIN TRAN t1"),
    content=(
      #|(begin-tran t1)
    ),
  )
  inspect(
    sx("BEGIN TRAN @name WITH MARK 'm'"),
    content=(
      #|(begin-tran @name)
    ),
  )
  inspect(
    sx("BEGIN DISTRIBUTED TRANSACTION"),
    content=(
      #|(begin-distributed-tran)
    ),
  )
  inspect(
    sx("COMMIT"),
    content=(
      #|(commit)
    ),
  )
  inspect(
    sx("COMMIT TRANSACTION t1"),
    content=(
      #|(commit t1)
    ),
  )
  inspect(
    sx("COMMIT WORK"),
    content=(
      #|(commit)
    ),
  )
  inspect(
    sx("ROLLBACK TRAN"),
    content=(
      #|(rollback)
    ),
  )
  inspect(
    sx("ROLLBACK TRANSACTION sp1"),
    content=(
      #|(rollback sp1)
    ),
  )
  inspect(
    sx("ROLLBACK TRANSACTION\nTHROW"),
    content=(
      #|(rollback THROW)
    ),
  )
  inspect(
    sx("SAVE TRAN sp1"),
    content=(
      #|(save sp1)
    ),
  )
  inspect(
    sx("SAVE TRANSACTION @sp"),
    content=(
      #|(save @sp)
    ),
  )
  inspect(
    sx("BEGIN TRAN\nINSERT t DEFAULT VALUES\nCOMMIT"),
    content=(
      #|(begin-tran)
      #|(insert (table t) default-values)
      #|(commit)
    ),
  )
}

///|
test "exec" {
  inspect(
    sx("EXEC sp_executesql N'SELECT @p', N'@p int', @p = 5"),
    content=(
      #|(exec sp_executesql N'SELECT @p' N'@p int' (arg @p 5))
    ),
  )
  inspect(
    sx("EXECUTE dbo.p 1, -2, 'x', @v OUTPUT, @n = @m OUT, DEFAULT, NULL"),
    content=(
      #|(exec dbo.p 1 (- 2) 'x' (arg @v output) (arg @n @m output) DEFAULT NULL)
    ),
  )
  inspect(
    sx("EXEC @rc = dbo.p @a = 1"),
    content=(
      #|(exec (returns @rc) dbo.p (arg @a 1))
    ),
  )
  inspect(
    sx("EXEC @proc"),
    content=(
      #|(exec @proc)
    ),
  )
  inspect(
    sx("EXEC sp_help mytable"),
    content=(
      #|(exec sp_help mytable)
    ),
  )
  inspect(
    sx("EXEC p WITH RECOMPILE"),
    content=(
      #|(exec p recompile)
    ),
  )
  inspect(
    sx("EXEC (@sql)"),
    content=(
      #|(exec-string @sql)
    ),
  )
  inspect(
    sx("EXEC ('SELECT ' + @col + ' FROM t')"),
    content=(
      #|(exec-string (+ (+ 'SELECT ' @col) ' FROM t'))
    ),
  )
  inspect(
    sx("EXEC p\nSELECT 1"),
    content=(
      #|(exec p)
      #|(select 1)
    ),
  )
  inspect(
    sx("EXEC p 1 + 1"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '+'.
    ),
  )
  inspect(
    sx("USE master"),
    content=(
      #|(use master)
    ),
  )
  inspect(
    sx("PRINT 'hello' + @x"),
    content=(
      #|(print (+ 'hello' @x))
    ),
  )
}

///|
test "cursors" {
  inspect(
    sx(
      (
        #|DECLARE items CURSOR LOCAL STATIC READ_ONLY FOR
        #|  SELECT id, name FROM products ORDER BY id
      ),
    ),
    content=(
      #|(declare-cursor items 'LOCAL' 'STATIC' 'READ_ONLY' (query (select id name (from (table products))) (order-by id)))
    ),
  )
  inspect(
    sx("DECLARE c CURSOR FAST_FORWARD FOR SELECT a FROM t FOR UPDATE OF a, b"),
    content=(
      #|(declare-cursor c 'FAST_FORWARD' (select a (from (table t))) (for-update a b))
    ),
  )
  inspect(
    sx("DECLARE c INSENSITIVE SCROLL CURSOR FOR SELECT a FROM t FOR READ ONLY"),
    content=(
      #|(declare-cursor c 'INSENSITIVE' 'SCROLL' 'READ ONLY' (select a (from (table t))))
    ),
  )
  inspect(
    sx("OPEN c"),
    content=(
      #|(open c)
    ),
  )
  inspect(
    sx("OPEN GLOBAL c"),
    content=(
      #|(open global c)
    ),
  )
  inspect(
    sx("FETCH NEXT FROM c INTO @id, @name"),
    content=(
      #|(fetch next c (into @id @name))
    ),
  )
  inspect(
    sx("FETCH FROM c"),
    content=(
      #|(fetch next c)
    ),
  )
  inspect(
    sx("FETCH c"),
    content=(
      #|(fetch next c)
    ),
  )
  inspect(
    sx("FETCH ABSOLUTE -2 FROM c INTO @id"),
    content=(
      #|(fetch (absolute (- 2)) c (into @id))
    ),
  )
  inspect(
    sx("FETCH RELATIVE @n FROM GLOBAL c"),
    content=(
      #|(fetch (relative @n) global c)
    ),
  )
  inspect(
    sx("FETCH PRIOR FROM @cv"),
    content=(
      #|(fetch prior @cv)
    ),
  )
  inspect(
    sx("CLOSE c"),
    content=(
      #|(close c)
    ),
  )
  inspect(
    sx("DEALLOCATE c"),
    content=(
      #|(deallocate c)
    ),
  )
  inspect(
    sx(
      (
        #|DECLARE @id INT;
        #|DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT id FROM t;
        #|OPEN c;
        #|FETCH NEXT FROM c INTO @id;
        #|WHILE @@FETCH_STATUS = 0
        #|BEGIN
        #|  PRINT @id;
        #|  FETCH NEXT FROM c INTO @id;
        #|END
        #|CLOSE c;
        #|DEALLOCATE c;
      ),
    ),
    content=(
      #|(declare (@id INT))
      #|(declare-cursor c 'LOCAL' 'FAST_FORWARD' (select id (from (table t))))
      #|(open c)
      #|(fetch next c (into @id))
      #|(while (= @@FETCH_STATUS 0) (block (print @id) (fetch next c (into @id))))
      #|(close c)
      #|(deallocate c)
    ),
  )
}

///|
test "batches" {
  inspect(
    sx("SET NOCOUNT ON;\nDECLARE @x INT = 1;\nSELECT @x;"),
    content=(
      #|(set-option (NOCOUNT) ON)
      #|(declare (@x INT 1))
      #|(select @x)
    ),
  )
  inspect(
    sx("DECLARE @x INT SET @x = 1 SELECT @x AS x"),
    content=(
      #|(declare (@x INT))
      #|(set @x = 1)
      #|(select (as @x x))
    ),
  )
  inspect(sx(""), content="")
  inspect(sx(";;"), content="")
  inspect(sx("-- just a comment\n/* and /* nested */ one */"), content="")
  inspect(
    sx("SELECT 1\nWITH c AS (SELECT 1 AS a) SELECT * FROM c"),
    content=(
      #|Msg 319, Level 15, State 1, Line 2: Incorrect syntax near the keyword 'with'. If this statement is a common table expression, an xmlnamespaces clause or a change tracking context clause, the previous statement must be terminated with a semicolon.
    ),
  )
  inspect(
    sx("SELECT 1;\nWITH c AS (SELECT 1 AS a) SELECT * FROM c"),
    content=(
      #|(select 1)
      #|(query (with (c (select (as 1 a)))) (select * (from (table c))))
    ),
  )
}
