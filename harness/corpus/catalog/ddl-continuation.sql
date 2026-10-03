-- Which DDL errors end the batch, DDL inside transactions (rollback undoes
-- catalog changes), and constraint-pair errors inside TRY/CATCH.
-- @step setup
CREATE TABLE dbo.a (id int NOT NULL CONSTRAINT pk_a PRIMARY KEY, x int NULL);
-- @step batch
CREATE TABLE dbo.a (id int);
SELECT 1 AS after_2714;
-- @step batch
ALTER TABLE dbo.a ADD CONSTRAINT pk_a PRIMARY KEY (x);
SELECT 1 AS after_1750;
-- @step batch
ALTER TABLE dbo.a DROP COLUMN nosuch;
SELECT 1 AS after_4924;
-- @step batch
DROP TABLE dbo.nosuch;
SELECT 1 AS after_3701;
-- @step batch
ALTER TABLE dbo.a DROP COLUMN id;
SELECT 1 AS after_4922;
-- @step batch
BEGIN TRY
  ALTER TABLE dbo.a ADD CONSTRAINT pk_a PRIMARY KEY (x);
END TRY
BEGIN CATCH
  SELECT ERROR_NUMBER() AS n, ERROR_STATE() AS s, ERROR_MESSAGE() AS m;
END CATCH;
-- @step batch
BEGIN TRAN;
CREATE TABLE dbo.t2 (i int NOT NULL CONSTRAINT pk_t2 PRIMARY KEY);
ALTER TABLE dbo.a ADD y int NULL;
CREATE INDEX ix_a_x ON dbo.a (x);
SELECT CASE WHEN OBJECT_ID('dbo.t2') IS NULL THEN 0 ELSE 1 END AS t2, COL_LENGTH('dbo.a', 'y') AS y, INDEXPROPERTY(OBJECT_ID('dbo.a'), 'ix_a_x', 'IsUnique') AS ix;
ROLLBACK;
SELECT CASE WHEN OBJECT_ID('dbo.t2') IS NULL THEN 0 ELSE 1 END AS t2, COL_LENGTH('dbo.a', 'y') AS y, INDEXPROPERTY(OBJECT_ID('dbo.a'), 'ix_a_x', 'IsUnique') AS ix;
-- @step batch
CREATE TABLE #tmp (id int NOT NULL PRIMARY KEY, v int NULL CHECK (v > 0));
ALTER TABLE #tmp ADD w int NULL;
INSERT INTO #tmp (id, v, w) VALUES (1, 2, 3);
SELECT id, v, w, COL_LENGTH('tempdb..#tmp', 'w') AS wl FROM #tmp;
CREATE INDEX ix_tmp ON #tmp (v);
DROP INDEX ix_tmp ON #tmp;
DROP TABLE #tmp;
