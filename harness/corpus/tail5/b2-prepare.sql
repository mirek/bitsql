-- EXEC sp_prepare of one non-SELECT statement in a T-SQL batch compiles it
-- and sends DONEINPROC with the statement's CurCmd: INSERT 195, DELETE 196,
-- UPDATE 197, MERGE 279, assignments 193 (count 0), SET option 185, CREATE
-- TABLE 198, BEGIN TRAN 212, PRINT 247 (no count); DML OUTPUT sends its
-- COLMETADATA first. Compile errors are the error + 8180; DECLARE and IF
-- prepare deferred (8182).
-- @step setup
CREATE TABLE t(a INT, b NVARCHAR(10)); INSERT INTO t VALUES (1, N'x'), (2, NULL);
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'UPDATE t SET a = a', 1; SELECT @h AS h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'@x int', N'INSERT INTO t VALUES (@x, N''y'')', 1; EXEC sp_execute @h, 9; SELECT COUNT(*) AS n FROM t; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'DELETE FROM t WHERE a = 9', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'@p INT OUTPUT', N'SET @p = 5', 1; SELECT @h AS h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'SET NOCOUNT ON', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'DECLARE @z int', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'UPDATE missing_t SET a = 1', 1; SELECT @h AS h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'UPDATE t SET zz = 1', 1; SELECT @h AS h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'@p INT', N'SELECT @p = a FROM t', 1; SELECT @h AS h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'IF 1 = 1 SELECT 1 AS x', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'MERGE t USING (SELECT 1 AS a) s ON t.a = s.a WHEN MATCHED THEN UPDATE SET b = N''m'';', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'UPDATE t SET a = a OUTPUT inserted.a', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'CREATE TABLE t2 (x int)', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'BEGIN TRAN', 1; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'PRINT 1', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'INSERT INTO t (zz) VALUES (1)', 1; SELECT @h AS h
