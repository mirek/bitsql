-- 8120/8121/8127 name a base table or view as written in FROM (schema
-- included, even when aliased); derived tables by alias. Probed 2026-10-04.
-- @step setup
CREATE TABLE dbo.gt (id int, g int, v int); CREATE TABLE #tg (g int, v int)
-- @step batch
SELECT g, COUNT(*) AS c FROM dbo.gt
-- @step batch
SELECT g, COUNT(*) AS c FROM gt
-- @step batch
SELECT g, COUNT(*) AS c FROM dbo.gt AS a
-- @step batch
SELECT a.g, COUNT(*) AS c FROM dbo.gt a
-- @step batch
SELECT gt.g, COUNT(*) AS c FROM dbo.gt
-- @step batch
SELECT dbo.gt.g, COUNT(*) AS c FROM dbo.gt
-- @step batch
SELECT g, COUNT(*) AS c FROM [dbo].[gt]
-- @step batch
SELECT g, COUNT(*) AS c FROM DBO.GT
-- @step batch
SELECT g, COUNT(*) AS c FROM #tg
-- @step batch
SELECT COUNT(*) AS c FROM dbo.gt HAVING g > 1
-- @step batch
SELECT COUNT(*) AS c FROM dbo.gt ORDER BY g
-- @step batch
SELECT v, COUNT(*) AS c FROM dbo.gt GROUP BY g
-- @step batch
SELECT g, COUNT(*) AS c FROM (SELECT * FROM dbo.gt) d
-- @step batch
SELECT g, COUNT(*) AS c FROM dbo.gt CROSS JOIN (SELECT 1 AS x) y
-- @step batch
SELECT x, g, COUNT(*) AS c FROM dbo.gt, (SELECT 1 AS x) y GROUP BY g
-- @step batch
SELECT g, COUNT(*) AS c FROM sys.objects o CROSS JOIN dbo.gt
-- @step batch
SELECT name, COUNT(*) AS c FROM sys.objects
-- @step batch
SELECT g, COUNT(*) AS c FROM dbo.gt WITH (NOLOCK)
-- @step batch
CREATE VIEW dbo.gv AS SELECT g, v FROM dbo.gt
-- @step batch
SELECT g, COUNT(*) AS c FROM dbo.gv
-- @step batch
SELECT g, COUNT(*) AS c FROM gv
-- @step batch
SELECT g, COUNT(*) AS c FROM gt a
-- @step batch
SELECT g, COUNT(*) AS c FROM dbo.[gt] AS [A b]
-- @step batch
SELECT g, COUNT(*) AS c FROM dbo.gt a JOIN dbo.gt b ON a.id = b.id GROUP BY b.g
