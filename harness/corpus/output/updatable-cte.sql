-- UPDATE/DELETE through a CTE or derived table that projects one base
-- table: the WHERE of the CTE applies, the inserted/deleted images have the
-- CTE's columns (computed ones evaluated, flags without fComputed), the CTE
-- name is the target alias and is not visible in OUTPUT.
-- @step setup
CREATE TABLE r(id INT NOT NULL PRIMARY KEY, n INT NULL, t NVARCHAR(4) NULL);
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1,N'one'),(20,2,N'two'),(30,3,N'thr');
-- @step batch
WITH c AS (SELECT id, n FROM r WHERE id<=20) UPDATE c SET n=n+100 OUTPUT inserted.*, deleted.n;
SELECT id, n, t FROM r ORDER BY id
-- @step batch
WITH c AS (SELECT id AS k, n AS v FROM r) UPDATE c SET v=7 OUTPUT inserted.v, deleted.k WHERE k=10;
SELECT id, n, t FROM r ORDER BY id
-- @step batch
WITH c(k, v) AS (SELECT id, n FROM r) UPDATE c SET c.v=v+1 OUTPUT inserted.*, deleted.* WHERE c.k=20
-- @step batch
WITH c AS (SELECT id AS k, n AS v FROM r) UPDATE c SET v=7 OUTPUT inserted.n WHERE k=10
-- @step batch
WITH c AS (SELECT id, n FROM r) UPDATE c SET n=2 OUTPUT deleted.t
-- @step batch
WITH c AS (SELECT id, n+1 AS m, 5 AS k, t FROM r) UPDATE c SET id=id+1000, t=N'big' OUTPUT inserted.*, deleted.m WHERE id=30;
SELECT id, n, t FROM r ORDER BY id
-- @step batch
WITH c AS (SELECT id, n+1 AS m FROM r) UPDATE c SET m=5
-- @step batch
WITH c AS (SELECT DISTINCT n FROM r) UPDATE c SET n=0
-- @step batch
WITH c AS (SELECT n, COUNT(*) AS k FROM r GROUP BY n) UPDATE c SET n=0
-- @step batch
WITH c AS (SELECT id, n FROM r) UPDATE c SET n=c.n+1 OUTPUT inserted.n, c.id FROM c WHERE c.id=10
-- @step batch
WITH c AS (SELECT id, n FROM r) UPDATE c SET n=c.n+1 OUTPUT inserted.n, deleted.id FROM c WHERE c.id=10
-- @step batch
WITH c AS (SELECT id, n FROM r), s AS (SELECT 20 AS id, 9 AS v) UPDATE c SET n=s.v OUTPUT deleted.id, inserted.n, s.v FROM c JOIN s ON c.id=s.id
-- @step batch
WITH c AS (SELECT * FROM r) UPDATE c SET n=0 OUTPUT inserted.* WHERE id=1030
-- @step setup
DELETE r; INSERT INTO r VALUES(10,1,N'one'),(20,2,N'two'),(30,3,N'thr');
-- @step batch
UPDATE x SET n=n+1 OUTPUT inserted.* FROM (SELECT id, n FROM r) x WHERE x.id=10
-- @step batch
UPDATE x SET n=x.n+s.d OUTPUT inserted.*, s.d FROM (SELECT id, n FROM r WHERE id>10) x JOIN (VALUES(10,1),(20,2)) s(id,d) ON x.id=s.id
-- @step batch
UPDATE x SET q=1 FROM (SELECT id, n*2 AS q FROM r) x
-- @step batch
WITH c AS (SELECT id, n FROM r WHERE id=20) DELETE c OUTPUT deleted.*;
SELECT id, n, t FROM r ORDER BY id
-- @step batch
WITH c AS (SELECT * FROM r) DELETE FROM c OUTPUT deleted.* WHERE id=10
-- @step batch
DELETE x OUTPUT deleted.* FROM (SELECT id AS k FROM r) x WHERE x.k=30
-- @step batch
SELECT id, n, t FROM r ORDER BY id
