-- Invalid SELECT TOP counts: constants fail the batch (127 negative, 1060
-- NULL row count, 1014 NULL percent, 1031 percent outside 0..100, class 15);
-- variables fail after COLMETADATA (NULL is 1014 for both forms).
-- @step setup
CREATE TABLE tp(id int); INSERT INTO tp VALUES (1),(2),(3);
-- @step batch
SELECT TOP (-1) id FROM tp ORDER BY id
-- @step batch
SELECT TOP (CAST(NULL AS INT)) id FROM tp ORDER BY id
-- @step batch
SELECT TOP (NULL) id FROM tp ORDER BY id
-- @step batch
SELECT TOP (NULL) PERCENT id FROM tp ORDER BY id
-- @step batch
DECLARE @n INT = -1; SELECT TOP (@n) id FROM tp ORDER BY id
-- @step batch
DECLARE @n INT = NULL; SELECT TOP (@n) id FROM tp ORDER BY id
-- @step batch
DECLARE @p FLOAT = 101; SELECT TOP (@p) PERCENT id FROM tp ORDER BY id
-- @step batch
DECLARE @p FLOAT = NULL; SELECT TOP (@p) PERCENT id FROM tp ORDER BY id
-- @step batch
DECLARE @n INT = -1; SELECT TOP (@n) WITH TIES id FROM tp ORDER BY id
-- @step batch
DECLARE @n INT = NULL; SELECT TOP (@n) WITH TIES id FROM tp ORDER BY id
-- @step batch
SELECT TOP (1-2) id FROM tp ORDER BY id
-- @step batch
SELECT 1 AS a; SELECT TOP (101) PERCENT id FROM tp ORDER BY id
-- @step batch
SELECT TOP (100.5) PERCENT id FROM tp ORDER BY id
-- @step batch
SELECT TOP (CAST(NULL AS INT)) PERCENT id FROM tp ORDER BY id
