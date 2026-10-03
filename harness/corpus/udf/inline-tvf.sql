-- Inline table-valued functions: parameters, DEFAULT arguments, CROSS and
-- OUTER APPLY with outer column arguments, unqualified names, aggregates
-- and INSERT ... SELECT over a function, result metadata (base columns keep
-- their flags, computed and parameter columns are 33), run-time errors, and
-- binding errors: 313/8144 (state 3, schema-qualified names report line
-- 13), 216 without arguments, 208 unknown / scalar function in FROM, 317
-- column alias, 4121 table function as a scalar.
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NULL, s nvarchar(20) NULL);
INSERT INTO dbo.t VALUES (1, 10, N'x'), (2, NULL, N'yy'), (3, 30, NULL);
-- @step batch
CREATE FUNCTION dbo.big (@min int) RETURNS TABLE AS RETURN SELECT id, a, s, a * 2 AS a2 FROM dbo.t WHERE id >= @min
-- @step batch
CREATE FUNCTION dbo.ser
  (@n int,
   @step int = 1)
RETURNS TABLE AS
RETURN (SELECT @n AS n,
   @n + @step AS n2, CAST(@n AS varchar(10)) AS txt)
-- @step batch
CREATE FUNCTION dbo.ierr (@n int) RETURNS TABLE AS RETURN SELECT id, 10 / (@n - id) AS q FROM dbo.t
-- @step batch
CREATE FUNCTION dbo.add1 (@x int) RETURNS int AS BEGIN RETURN @x + 1 END
-- @step batch
CREATE FUNCTION dbo.viaudf (@x int) RETURNS TABLE AS RETURN SELECT dbo.add1(@x) AS y, b.id FROM dbo.big(@x) AS b
-- @step batch
SELECT * FROM dbo.big(2) ORDER BY id
-- @step batch
SELECT b.id, b.a2, x.n, x.n2 FROM dbo.big(1) AS b CROSS APPLY dbo.ser(b.id, DEFAULT) AS x ORDER BY b.id
-- @step batch
SELECT t.id, x.* FROM dbo.t AS t OUTER APPLY dbo.big(t.id + 1) AS x ORDER BY t.id, x.id
-- @step batch
SELECT * FROM dbo.ser(5, DEFAULT)
-- @step batch
SELECT * FROM big(1)
-- @step batch
DECLARE @x int = 2;
SELECT COUNT(*) AS c FROM dbo.big(@x);
SELECT * FROM dbo.viaudf(@x) ORDER BY id;
-- @step batch
SELECT * FROM dbo.big(1) WHERE a IS NULL;
INSERT INTO dbo.t SELECT id + 10, a, s FROM dbo.big(1);
SELECT COUNT(*) AS c FROM dbo.t;
-- @step batch
SELECT * FROM dbo.ser('x', 1)
-- @step batch
SELECT 1 AS x;
SELECT * FROM dbo.ierr(2);
SELECT 2 AS y;
-- @step batch
SELECT * FROM dbo.ser(5)
-- @step batch
-- the reported line is 13 for a schema-qualified name
-- whatever the statement's line
SELECT * FROM dbo.ser(1)
-- @step batch
SELECT * FROM [DBO].[SER](5, 1, 2)
-- @step batch
SELECT * FROM ser(5)
-- @step batch
SELECT * FROM dbo.ser
-- @step batch
SELECT * FROM SER
-- @step batch
SELECT * FROM dbo.nosuch(1)
-- @step batch
SELECT * FROM dbo.add1(1)
-- @step batch
SELECT * FROM dbo.ser(1, DEFAULT) AS s(a, b, c)
-- @step batch
SELECT dbo.ser(1, 2)
-- @step batch
SELECT CASE WHEN OBJECT_ID('dbo.big', 'IF') IS NOT NULL THEN 1 ELSE 0 END AS i,
  OBJECTPROPERTY(OBJECT_ID('dbo.big'), 'IsInlineFunction') AS inl,
  OBJECTPROPERTY(OBJECT_ID('dbo.big'), 'IsTableFunction') AS tf;
SELECT name, type, type_desc FROM sys.objects WHERE name IN ('big', 'ser') ORDER BY name;
-- @step batch
DROP FUNCTION dbo.ierr;
DROP FUNCTION IF EXISTS dbo.ierr;
SELECT OBJECT_ID('dbo.ierr') AS gone;
-- @step batch
DROP FUNCTION dbo.ierr
