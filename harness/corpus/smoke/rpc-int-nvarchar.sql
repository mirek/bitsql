-- Parameterized sp_executesql (tedious execSql) with int and nvarchar params.
-- @step rpc
-- @param @a int = 41
-- @param @b nvarchar(10) = "hello"
SELECT @a + 1 AS next, @b AS greeting, LEN(@b) AS len
