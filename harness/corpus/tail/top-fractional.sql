-- A non-integer TOP row count: constants are 1060 for the whole batch;
-- variables of decimal/float types.
-- @step setup
CREATE TABLE tp(id int); INSERT INTO tp VALUES (1),(2),(3);
-- @step batch
SELECT TOP (1.5) id FROM tp ORDER BY id
-- @step batch
SELECT TOP (2.0) id FROM tp ORDER BY id
-- @step batch
SELECT TOP (CAST(2 AS FLOAT)) id FROM tp ORDER BY id
-- @step batch
DECLARE @d DECIMAL(5,1) = 1.5; SELECT TOP (@d) id FROM tp ORDER BY id
-- @step batch
DECLARE @f FLOAT = 2; SELECT TOP (@f) id FROM tp ORDER BY id
-- @step batch
UPDATE TOP (1.5) tp SET id = id
-- @step batch
SELECT TOP (CAST(2 AS BIGINT)) id FROM tp ORDER BY id
-- @step batch
SELECT TOP ('2') id FROM tp ORDER BY id
