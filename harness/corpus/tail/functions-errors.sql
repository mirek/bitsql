-- Errors that end the batch (289 from *FROMPARTS, 8169 GUID conversion)
-- and compile-time DECLARE: a variable declared in a branch that does not
-- run exists, a DECLARE in a loop keeps its value.
-- @step batch
SELECT DATEFROMPARTS(2023, 2, 29) AS d;
SELECT 1 AS after_289
-- @step batch
SELECT CAST('bad' AS uniqueidentifier) AS g;
SELECT 1 AS after_8169
-- @step batch
BEGIN TRY SELECT TIMEFROMPARTS(24, 0, 0, 0, 0) AS t END TRY BEGIN CATCH SELECT ERROR_NUMBER() AS n, ERROR_STATE() AS s END CATCH;
SELECT 2 AS after_caught
-- @step batch
DECLARE @i int = 0, @s int = 0;
WHILE @i < 3 BEGIN SET @i += 1; DECLARE @z int; SET @z = ISNULL(@z, 0) + 1; DECLARE @w int = 10; SET @w += 1; SET @s += @z + @w END;
SELECT @s AS s, @w AS w;
IF 1 = 0 BEGIN DECLARE @y int = 5 END;
SELECT ISNULL(@y, -1) AS y
-- @step batch
SELECT TIMEFROMPARTS(1, 2, 3, 0, 7 & 3) AS t, DATETIME2FROMPARTS(2024, 1, 1, 1, 2, 3, 0, 1 | 2) AS d
