-- Scalar user-defined function errors: binding (195 unqualified, 4121
-- unknown or table-valued, 313/8144 argument counts, 206 incompatible
-- argument), run-time conversion and arithmetic errors raised inside a
-- function (reported at the caller's line; ERROR_PROCEDURE is NULL), errors
-- mid-result, nesting limit 217 (ends the batch).
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY);
INSERT INTO dbo.t VALUES (1), (2), (3);
-- @step batch
CREATE FUNCTION dbo.add1 (@x int) RETURNS int AS BEGIN RETURN @x + 1 END
-- @step batch
CREATE FUNCTION dbo.dflt (@x int, @y int = 5) RETURNS int AS BEGIN RETURN @x + @y END
-- @step batch
CREATE FUNCTION dbo.div (@a int,
  @b int) RETURNS int AS
BEGIN
  DECLARE @r int;
  SET @r = @a / @b;
  RETURN @r
END
-- @step batch
CREATE FUNCTION dbo.fact (@n int) RETURNS bigint AS
BEGIN
  IF @n <= 1 RETURN 1;
  RETURN @n * dbo.fact(@n - 1);
END
-- @step batch
CREATE FUNCTION dbo.tf (@x int) RETURNS TABLE AS RETURN SELECT @x AS x
-- @step batch
SELECT add1(1)
-- @step batch
SELECT dbo.dflt(2)
-- @step batch
SELECT dbo.dflt(2, 3, 4)
-- @step batch
SELECT dbo.nosuch(1)
-- @step batch
SELECT dbo.tf(1)
-- @step batch
SELECT dbo.add1(CAST('2020-01-01' AS date))
-- @step batch
SELECT dbo.add1('abc') AS v
-- @step batch
SELECT dbo.add1(2147483647) AS v
-- @step batch
SELECT 1 AS x;
SELECT dbo.div(1, 0) AS z;
SELECT 2 AS y;
-- @step batch
SELECT id, dbo.div(10, id - 2) AS z FROM dbo.t ORDER BY id
-- @step batch
BEGIN TRY
  SELECT dbo.div(1, 0) AS z;
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS n, ERROR_LINE() AS l, ERROR_PROCEDURE() AS p, ERROR_MESSAGE() AS m;
END CATCH
-- @step batch
DECLARE @v int;
SET @v = dbo.div(1, 0);
SELECT @v AS v, @@ERROR AS e;
-- @step batch
SELECT dbo.fact(32) AS f
-- @step batch
SELECT 1 AS x;
SELECT dbo.fact(33) AS f;
SELECT 2 AS y;
-- @step batch
SELECT 'after' AS a
