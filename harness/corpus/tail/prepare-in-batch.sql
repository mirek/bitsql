-- EXEC sp_prepare / sp_execute / sp_unprepare in a T-SQL batch: a single
-- SELECT compiles at prepare time and sends its COLMETADATA (no rows); a
-- compile error is the error + 8180 and no handle; several statements or a
-- syntax error prepare without compiling (status 8182); @options = 0 is
-- 214 state 3; unknown handles are 8179 state 4 (execute) / 8 (unprepare).
-- @step setup
CREATE TABLE t(a INT, b NVARCHAR(10)); INSERT INTO t VALUES (1, N'x'), (2, NULL);
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'@p INT', N'SELECT a, b FROM t WHERE a > @p'; SELECT @h AS h; EXEC sp_execute @h, 0; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT, @r INT; EXEC @r = sp_prepare @h OUTPUT, N'@p INT', N'SELECT a, b FROM t WHERE a > @p', 0; SELECT @h AS h, @r AS r; EXEC @r = sp_execute @h, 1; SELECT @r AS r; EXEC @r = sp_unprepare @h; SELECT @r AS r
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'SELECT * FROM missing_t', 1; SELECT @h AS h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'SELECT 1 AS x; SELECT 2 AS y', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @r INT; EXEC @r = sp_execute 12345; SELECT @r AS r
-- @step batch
DECLARE @r INT; EXEC @r = sp_unprepare 12345; SELECT @r AS r
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'@p INT', N'SELECT 1/@p AS q', 1; EXEC sp_execute @h, 0; SELECT 7 AS after_err; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'SELEC 1', 1; SELECT @h AS h
