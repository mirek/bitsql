-- CREATE FUNCTION body checks: side-effecting operators (443 with the
-- operator name and state, several reported together, in order), SELECTs
-- returning data (444, state 3 scalar / 2 table-valued), temporary tables
-- (2772), the last statement must be RETURN (455), RETURN forms (1075,
-- 178). Allowed: table variable DML, SELECT assignments, cursors, GETDATE.
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NULL);
-- @step batch
CREATE FUNCTION dbo.b1 (@x int) RETURNS int AS BEGIN INSERT INTO dbo.t VALUES (@x, 1); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b2 (@x int) RETURNS int AS BEGIN UPDATE dbo.t SET a = 1; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b3 () RETURNS int AS BEGIN DELETE FROM dbo.t; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b4 () RETURNS int AS BEGIN MERGE dbo.t AS d USING (SELECT 1 AS id) AS s ON d.id = s.id WHEN MATCHED THEN DELETE; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b5 (@x int) RETURNS int AS BEGIN PRINT 'x'; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b6 (@x int) RETURNS int AS BEGIN RAISERROR('x', 16, 1); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b7 (@x int) RETURNS int AS BEGIN THROW 50000, 'x', 1; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b8 () RETURNS int AS BEGIN BEGIN TRY PRINT 1 END TRY BEGIN CATCH PRINT 2 END CATCH; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b9 () RETURNS int AS BEGIN BEGIN TRAN; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b10 () RETURNS int AS BEGIN COMMIT; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b11 () RETURNS int AS BEGIN ROLLBACK; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b12 () RETURNS int AS BEGIN SAVE TRANSACTION s; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b13 (@x int) RETURNS int AS BEGIN SET NOCOUNT ON; RETURN @x END
-- @step batch
CREATE FUNCTION dbo.b14 () RETURNS int AS BEGIN SET NOCOUNT OFF; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b15 () RETURNS int AS BEGIN CREATE TABLE dbo.x (a int); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b16 () RETURNS int AS BEGIN TRUNCATE TABLE dbo.t; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b17 (@x int) RETURNS int AS BEGIN EXEC ('select 1'); RETURN @x END
-- @step batch
CREATE FUNCTION dbo.b18 () RETURNS int AS BEGIN PRINT 1; PRINT 2; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b19 () RETURNS int AS BEGIN PRINT 1; SELECT 1 AS x; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b20 (@x int) RETURNS int AS BEGIN DELETE FROM dbo.nosuch; PRINT 1; RETURN @x END
-- @step batch
CREATE FUNCTION dbo.b21 (@x int) RETURNS int AS BEGIN SELECT @x AS x; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b22 () RETURNS @t TABLE (a int) AS BEGIN INSERT INTO @t SELECT id FROM dbo.t; SELECT * FROM @t; RETURN END
-- @step batch
CREATE FUNCTION dbo.b23 (@x int) RETURNS int AS BEGIN CREATE TABLE #x (a int); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b24 (@x int) RETURNS int AS BEGIN DECLARE @v int; SELECT @v = COUNT(*) FROM #tmp; RETURN @v END
-- @step batch
CREATE FUNCTION dbo.b25 (@x int) RETURNS int AS BEGIN DECLARE @v int = NEWID(); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b26 (@x int) RETURNS int AS BEGIN DECLARE @r float = RAND(); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b27 () RETURNS int AS BEGIN DECLARE @v uniqueidentifier = NEWSEQUENTIALID(); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.b28 (@x int) RETURNS int AS BEGIN SET @x = 1 END
-- @step batch
CREATE FUNCTION dbo.b29 (@x int) RETURNS int AS BEGIN IF @x > 0 RETURN 1 ELSE RETURN 2 END
-- @step batch
CREATE FUNCTION dbo.b30 () RETURNS int AS BEGIN DECLARE @v int; RETURN @v; SET @v = 1 END
-- @step batch
CREATE FUNCTION dbo.b31 (@x int) RETURNS @t TABLE (a int) AS BEGIN INSERT INTO @t VALUES (1) END
-- @step batch
CREATE FUNCTION dbo.b32 (@x int) RETURNS @t TABLE (a int) AS BEGIN INSERT INTO @t VALUES (1); RETURN 5 END
-- @step batch
CREATE FUNCTION dbo.b33 (@x int) RETURNS int AS BEGIN RETURN END
-- @step batch
CREATE FUNCTION dbo.ok1 (@x int) RETURNS int AS BEGIN BEGIN RETURN 1 END END
-- @step batch
CREATE FUNCTION dbo.ok2 (@x int) RETURNS int AS BEGIN WHILE 1 = 0 BREAK; RETURN @x END
-- @step batch
CREATE FUNCTION dbo.ok3 () RETURNS int AS BEGIN DECLARE @v datetime = GETDATE(); RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.ok4 () RETURNS int AS BEGIN DECLARE c CURSOR FOR SELECT id FROM dbo.t; RETURN 1 END
-- @step batch
CREATE FUNCTION dbo.ok5 (@x int) RETURNS int AS BEGIN DECLARE @t TABLE (a int); DELETE FROM @t; UPDATE @t SET a = 1; INSERT INTO @t VALUES (@x); RETURN @x END
-- @step batch
SELECT name FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') ORDER BY name;
SELECT dbo.ok1(0) AS a, dbo.ok2(3) AS b, dbo.ok5(4) AS c;
