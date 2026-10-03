-- Scalar user-defined functions: calls in SELECT (with and without FROM),
-- WHERE, ORDER BY, assignments, PRINT, UPDATE, computed columns, defaults
-- and CHECK constraints; argument conversion, DEFAULT arguments, NULL
-- handling (RETURNS NULL ON NULL INPUT), procedural bodies (WHILE, IF,
-- table variables, SELECT assignments), recursion, @@NESTLEVEL, result
-- metadata, EXEC of a scalar function and OBJECT_ID type codes.
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NULL, s nvarchar(20) NULL);
INSERT INTO dbo.t VALUES (1, 10, N'x'), (2, NULL, N'yy'), (3, 30, NULL);
-- @step batch
CREATE FUNCTION dbo.add1 (@x int) RETURNS int AS BEGIN RETURN @x + 1 END
-- @step batch
CREATE FUNCTION dbo.dflt (@x int, @y int = 5) RETURNS decimal(10,2) AS
BEGIN
  DECLARE @r decimal(10,2);
  SET @r = @x * 1.5 + @y;
  RETURN @r
END
-- @step batch
CREATE FUNCTION dbo.nm (@s nvarchar(5)) RETURNS varchar(3) AS BEGIN RETURN @s END
-- @step batch
CREATE FUNCTION dbo.loopy (@n int) RETURNS int AS
BEGIN
  DECLARE @i int = 0, @acc int = 0;
  WHILE @i < @n
  BEGIN
    SET @i += 1;
    IF @i % 2 = 0 CONTINUE;
    IF @i > 7 BREAK;
    SET @acc += @i;
  END
  RETURN @acc
END
-- @step batch
CREATE FUNCTION dbo.tv (@x int) RETURNS int AS
BEGIN
  DECLARE @t TABLE (a int);
  INSERT INTO @t VALUES (@x), (@x * 2);
  UPDATE @t SET a = a + 1 WHERE a = @x;
  DELETE FROM @t WHERE a > 100;
  SELECT @x = MAX(a) + COUNT(*) FROM @t;
  RETURN @x
END
-- @step batch
CREATE FUNCTION dbo.fact (@n int) RETURNS bigint AS
BEGIN
  IF @n <= 1 RETURN 1;
  RETURN @n * dbo.fact(@n - 1);
END
-- @step batch
CREATE FUNCTION dbo.nn (@a int, @b nvarchar(10)) RETURNS nvarchar(30) WITH RETURNS NULL ON NULL INPUT AS
BEGIN
  RETURN CONCAT(N'[', @a, N'|', @b, N']')
END
-- @step batch
CREATE FUNCTION dbo.cn (@a int, @b nvarchar(10)) RETURNS nvarchar(30) AS
BEGIN
  RETURN CONCAT(N'[', @a, N'|', @b, N']')
END
-- @step batch
CREATE FUNCTION dbo.depth (@n int) RETURNS int AS BEGIN RETURN @@NESTLEVEL + 0 * @n END
-- @step batch
CREATE FUNCTION dbo.cnt () RETURNS int AS BEGIN RETURN (SELECT COUNT(*) FROM dbo.t) END
-- @step batch
CREATE FUNCTION dbo.nested (@x int) RETURNS int AS BEGIN BEGIN RETURN dbo.add1(dbo.add1(@x)) END END
-- @step batch
SELECT dbo.add1(1) AS a, dbo.add1(NULL) AS b, dbo.dflt(2, DEFAULT) AS c, dbo.dflt(2, 1) AS d, dbo.nm(N'abcdefgh') AS e,
  dbo.add1(DEFAULT) AS f, dbo.add1('41') AS g, dbo.add1(2.9) AS h, [dbo].[ADD1](3) AS i
-- @step batch
SELECT id, dbo.add1(a) AS p, dbo.add1(id) AS q FROM dbo.t WHERE dbo.add1(id) > 2 ORDER BY dbo.add1(id) DESC
-- @step batch
SELECT id, dbo.add1(id) AS q FROM dbo.t ORDER BY q DESC
-- @step batch
SELECT dbo.loopy(10) AS l10, dbo.loopy(0) AS l0, dbo.tv(4) AS tv4, dbo.fact(5) AS f5, dbo.fact(20) AS f20, dbo.nested(1) AS n1
-- @step batch
SELECT dbo.nn(NULL, N'a') AS a, dbo.nn(1, NULL) AS b, dbo.nn(1, N'z') AS c, dbo.cn(NULL, NULL) AS d
-- @step batch
SELECT dbo.depth(1) AS d, @@NESTLEVEL AS n
-- @step batch
DECLARE @v int = dbo.add1(41);
SELECT @v AS v;
SET @v = dbo.add1(@v);
PRINT @v;
SELECT @v = dbo.add1(id) FROM dbo.t WHERE id = 3;
SELECT @v AS v2;
-- @step batch
UPDATE dbo.t SET a = dbo.add1(a) WHERE id = 1;
SELECT id, a FROM dbo.t WHERE id = 1;
-- @step batch
INSERT INTO dbo.t VALUES (4, dbo.cnt(), N'c'), (5, dbo.cnt(), N'c');
SELECT id, a, dbo.cnt() AS c FROM dbo.t WHERE id >= 4 ORDER BY id;
-- @step batch
CREATE TABLE dbo.c (
  id int NOT NULL,
  f AS dbo.fact(id),
  d bigint NULL CONSTRAINT df_c DEFAULT (dbo.fact(3)),
  CONSTRAINT ck_c CHECK (dbo.fact(id) < 1000 OR d IS NULL));
-- @step batch
INSERT INTO dbo.c (id) VALUES (3), (4);
SELECT id, f, d FROM dbo.c ORDER BY id;
-- @step batch
DECLARE @r int;
EXEC @r = dbo.add1 @x = 5;
SELECT @r AS r;
EXEC dbo.add1 6;
-- @step batch
SELECT CASE WHEN OBJECT_ID('dbo.add1', 'FN') IS NOT NULL THEN 1 ELSE 0 END AS fn,
  CASE WHEN OBJECT_ID('dbo.add1', 'IF') IS NULL THEN 1 ELSE 0 END AS not_if,
  OBJECTPROPERTY(OBJECT_ID('dbo.add1'), 'IsScalarFunction') AS scalar,
  OBJECT_NAME(OBJECT_ID('dbo.add1')) AS n;
SELECT name, type, type_desc FROM sys.objects WHERE name IN ('add1', 'fact', 'nn') ORDER BY name;
