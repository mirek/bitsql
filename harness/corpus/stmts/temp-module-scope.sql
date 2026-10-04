-- Local temp tables created by a procedure or dynamic SQL are dropped when
-- it ends; global ## tables survive. Table variables declared in a loop
-- keep their rows, ones declared in a skipped branch exist.
-- @step setup
CREATE PROCEDURE dbo.mk_temp AS BEGIN CREATE TABLE #p(a int); INSERT #p VALUES (1); SELECT a FROM #p END
-- @step batch
EXEC dbo.mk_temp; SELECT OBJECT_ID('tempdb..#p') AS still_there
-- @step batch
EXEC sp_executesql N'CREATE TABLE #q(a int); CREATE TABLE ##q2(a int)'; SELECT OBJECT_ID('tempdb..#q') AS local_q, CASE WHEN OBJECT_ID('tempdb..##q2') IS NULL THEN 0 ELSE 1 END AS global_q; DROP TABLE ##q2
-- @step rpc
CREATE TABLE #r(id int); INSERT #r VALUES (20); SELECT id FROM #r
-- @step batch
SELECT OBJECT_ID('tempdb..#r') AS object_id
-- @step batch
DECLARE @i int = 0; WHILE @i < 3 BEGIN DECLARE @t TABLE(id int); INSERT @t VALUES (@i); SET @i += 1 END; SELECT id FROM @t ORDER BY id
-- @step batch
WHILE 1 = 0 BEGIN DECLARE @w TABLE(id int) END; INSERT @w VALUES (5); SELECT id FROM @w
-- @step batch
IF 1 = 1 SELECT 1 AS one ELSE BEGIN DECLARE @e TABLE(id int) END; INSERT @e VALUES (6); SELECT id FROM @e
-- @step batch
DECLARE @ids TABLE(id int PRIMARY KEY); INSERT @ids VALUES (1), (2); UPDATE i SET id = id + 10 FROM @ids AS i WHERE i.id = 1; DELETE d FROM @ids AS d WHERE d.id = 2; SELECT id FROM @ids
