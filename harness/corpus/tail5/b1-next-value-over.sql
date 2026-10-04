-- NEXT VALUE FOR seq OVER (ORDER BY ...): values follow the OVER order;
-- same OVER shares values; 11727/11716/11717/11718/11737/11720/11721/
-- 11723/11739/5308. Probed 2026-10-04. (ORDER BY SUM(n) OVER () inside the
-- OVER kills the SQL Server session with 596: not captured.)
-- @step setup
CREATE SEQUENCE dbo.sq AS int START WITH 1 INCREMENT BY 1; CREATE SEQUENCE dbo.sd AS smallint START WITH 0 INCREMENT BY -1 MINVALUE -2 MAXVALUE 0 NO CACHE; CREATE SEQUENCE dbo.sx AS int START WITH 1 MAXVALUE 2 NO CACHE; CREATE TABLE dbo.st (n int, g int, s varchar(5)); INSERT INTO dbo.st VALUES (3,1,'c'),(1,2,'a'),(2,1,'b')
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n DESC) AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY s DESC, n) AS v FROM dbo.st ORDER BY v
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS w FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v, NEXT VALUE FOR dbo.sq OVER (ORDER BY n DESC) AS w FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v, NEXT VALUE FOR dbo.sq AS w FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (PARTITION BY g ORDER BY n) AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER () AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n ROWS UNBOUNDED PRECEDING) AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER w AS v FROM dbo.st WINDOW w AS (ORDER BY n) ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) + 100 AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v, ROW_NUMBER() OVER (ORDER BY n DESC) AS r FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v FROM dbo.st
-- @step batch
DECLARE @t TABLE (v int, n int); INSERT INTO @t SELECT NEXT VALUE FOR dbo.sq OVER (ORDER BY n DESC), n FROM dbo.st; SELECT * FROM @t ORDER BY n
-- @step batch
SELECT NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v INTO #x FROM dbo.st; SELECT v FROM #x ORDER BY v
-- @step batch
UPDATE dbo.st SET g = NEXT VALUE FOR dbo.sq OVER (ORDER BY n)
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sd OVER (ORDER BY n) AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT current_value FROM sys.sequences WHERE name = 'sd'
-- @step batch
SELECT NEXT VALUE FOR dbo.sq OVER (ORDER BY 1) AS v
-- @step batch
SELECT NEXT VALUE FOR dbo.sq OVER (ORDER BY (SELECT 1)) AS v FROM dbo.st
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v FROM dbo.st WHERE n > 1 ORDER BY n
-- @step batch
SELECT TOP 2 n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v FROM dbo.st ORDER BY n DESC
-- @step batch
SELECT g, NEXT VALUE FOR dbo.sq OVER (ORDER BY g) AS v FROM dbo.st GROUP BY g ORDER BY g
-- @step batch
SELECT n, (SELECT NEXT VALUE FOR dbo.sq OVER (ORDER BY n)) AS v FROM dbo.st
-- @step batch
SELECT s, NEXT VALUE FOR dbo.sq OVER (ORDER BY s) AS v FROM dbo.st ORDER BY s
-- @step batch
SELECT current_value FROM sys.sequences WHERE name = 'sq'
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n COLLATE Latin1_General_BIN) AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT s, NEXT VALUE FOR dbo.sq OVER (ORDER BY s) AS v FROM dbo.st ORDER BY s
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v, NEXT VALUE FOR dbo.sq AS w FROM dbo.st
-- @step batch
SELECT n FROM dbo.st WHERE n = NEXT VALUE FOR dbo.sq OVER (ORDER BY n)
-- @step batch
SELECT n FROM dbo.st ORDER BY NEXT VALUE FOR dbo.sq OVER (ORDER BY n)
-- @step batch
DECLARE @t TABLE (v int); INSERT INTO @t VALUES (NEXT VALUE FOR dbo.sq OVER (ORDER BY (SELECT 1)))
-- @step batch
DECLARE @v int = NEXT VALUE FOR dbo.sq OVER (ORDER BY (SELECT 1)); SELECT @v AS v
-- @step batch
DECLARE @v int; SELECT @v = NEXT VALUE FOR dbo.sq OVER (ORDER BY n) FROM dbo.st; SELECT @v AS v
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n), SUM(n) OVER (ORDER BY n DESC) AS t FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v FROM dbo.st ORDER BY n OFFSET 0 ROWS
-- @step batch
SELECT TOP 2 n, NEXT VALUE FOR dbo.sq AS v FROM dbo.st
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq AS v FROM dbo.st ORDER BY n
-- @step batch
SELECT DISTINCT NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v FROM dbo.st
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n, g) AS v, NEXT VALUE FOR dbo.sq OVER (ORDER BY n,g) AS w FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n ASC) AS v, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS w FROM dbo.st ORDER BY n
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v FROM dbo.st UNION ALL SELECT 1, 1
-- @step batch
SELECT current_value FROM sys.sequences WHERE name = 'sq'
-- @step batch
SELECT n, NEXT VALUE FOR dbo.sx OVER (ORDER BY n DESC) AS v FROM dbo.st
-- @step batch
SELECT current_value FROM sys.sequences WHERE name = 'sx'
-- @step batch
SELECT 1 AS a; SELECT n, NEXT VALUE FOR dbo.sq OVER (PARTITION BY g ORDER BY n) AS v FROM dbo.st
-- @step batch
MERGE dbo.st AS t USING (SELECT 1 AS n) AS s ON t.n = s.n WHEN MATCHED THEN UPDATE SET g = NEXT VALUE FOR dbo.sq OVER (ORDER BY s.n);
-- @step batch
CREATE TABLE dbo.sdef (a int DEFAULT NEXT VALUE FOR dbo.sq OVER (ORDER BY (SELECT 1)))
-- @step batch
SELECT NEXT VALUE FOR dbo.sq OVER (ORDER BY n) AS v, n FROM dbo.st GROUP BY n
-- @step batch
SELECT current_value FROM sys.sequences WHERE name = 'sq'
