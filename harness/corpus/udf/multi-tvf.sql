-- Multi-statement table-valued functions: the body fills the declared
-- return table (DEFAULTs, PRIMARY KEY), loops, DML on the return table;
-- CROSS/OUTER APPLY; result metadata from the declared columns; an error
-- inside is followed by 3621; ALTER FUNCTION replaces the body; OBJECT_ID
-- 'TF' and DROP FUNCTION.
-- @step setup
CREATE TABLE dbo.t (id int NOT NULL PRIMARY KEY, a int NULL);
INSERT INTO dbo.t VALUES (1, 10), (2, NULL), (3, 30);
-- @step batch
CREATE FUNCTION dbo.ms (@n int) RETURNS @r TABLE (k int NOT NULL PRIMARY KEY, v nvarchar(10) NULL, d decimal(5,1) DEFAULT 1.5) AS
BEGIN
  DECLARE @i int = 1;
  WHILE @i <= @n
  BEGIN
    INSERT INTO @r (k, v) VALUES (@i, REPLICATE(N'z', @i));
    SET @i += 1;
  END
  UPDATE @r SET d = k * 2 WHERE k = 2;
  DELETE FROM @r WHERE k = 3;
  RETURN
END
-- @step batch
CREATE FUNCTION dbo.mserr (@n int) RETURNS @r TABLE (k int) AS
BEGIN
  INSERT INTO @r VALUES (1);
  INSERT INTO @r VALUES (10 / @n);
  RETURN
END
-- @step batch
CREATE FUNCTION dbo.early (@n int) RETURNS @r TABLE (k int, src int NULL) AS
BEGIN
  INSERT INTO @r SELECT id, a FROM dbo.t WHERE id <= @n;
  IF @n < 2 RETURN;
  INSERT INTO @r VALUES (100, NULL);
  RETURN
END
-- @step batch
SELECT * FROM dbo.ms(4) ORDER BY k
-- @step batch
SELECT t.id, m.k, m.v FROM dbo.t AS t CROSS APPLY dbo.ms(t.id) AS m ORDER BY t.id, m.k
-- @step batch
SELECT t.id, e.k FROM dbo.t AS t OUTER APPLY dbo.early(t.id - 1) AS e ORDER BY t.id, e.k
-- @step batch
SELECT * FROM dbo.early(3) ORDER BY k
-- @step batch
SELECT 1 AS x;
SELECT * FROM dbo.mserr(0);
SELECT 2 AS y;
-- @step batch
BEGIN TRY
  SELECT * FROM dbo.mserr(0);
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS n, ERROR_LINE() AS l;
END CATCH
-- @step batch
SELECT * FROM dbo.ms
-- @step batch
SELECT * FROM dbo.ms(1, 2)
-- @step batch
SELECT dbo.ms(1)
-- @step batch
ALTER FUNCTION dbo.mserr (@n int) RETURNS @r TABLE (k int, w varchar(5)) AS
BEGIN
  INSERT INTO @r VALUES (@n, 'w');
  RETURN
END
-- @step batch
SELECT * FROM dbo.mserr(0)
-- @step batch
SELECT CASE WHEN OBJECT_ID('dbo.ms', 'TF') IS NOT NULL THEN 1 ELSE 0 END AS m,
  OBJECTPROPERTY(OBJECT_ID('dbo.ms'), 'IsTableFunction') AS tf;
SELECT name, type, type_desc FROM sys.objects WHERE name IN ('ms', 'mserr', 'early') ORDER BY name;
-- @step batch
DROP FUNCTION dbo.ms, dbo.mserr;
SELECT name FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') ORDER BY name;
