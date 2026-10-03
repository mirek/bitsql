-- Trap: ORDER BY a column that is not in the select list changes result
-- metadata: computed expressions lose the fComputed flag (33 -> 1), and
-- computed catalog-view columns read as plain columns (33 -> 9).
-- @step setup
CREATE TABLE dbo.t (a int NULL, b int NULL, c AS a + 1);
INSERT INTO dbo.t (a, b) VALUES (1, 2);
-- @step batch
SELECT a + 1 AS x, c FROM dbo.t ORDER BY b;
SELECT a + 1 AS x, c, b FROM dbo.t ORDER BY b;
SELECT a + 1 AS x, c FROM dbo.t;
SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 't' ORDER BY ORDINAL_POSITION;
SELECT COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 't' ORDER BY ORDINAL_POSITION;
