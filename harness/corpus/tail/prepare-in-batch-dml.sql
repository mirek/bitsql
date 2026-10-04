-- EXEC sp_prepare of a DML or SET statement in a T-SQL batch (bitsql:
-- explicit Emulator error until these shapes are emulated).
-- @step setup
CREATE TABLE t(a INT, b NVARCHAR(10)); INSERT INTO t VALUES (1, N'x'), (2, NULL);
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'', N'UPDATE t SET a = a', 1; EXEC sp_execute @h; EXEC sp_unprepare @h
-- @step batch
DECLARE @h INT; EXEC sp_prepare @h OUTPUT, N'@p INT OUTPUT', N'SET @p = 5', 1; DECLARE @o INT; EXEC sp_execute @h, @o OUTPUT; SELECT @o AS o; EXEC sp_unprepare @h
