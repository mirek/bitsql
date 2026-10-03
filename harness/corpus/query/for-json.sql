-- FOR JSON PATH / AUTO: column name, type, row splitting, options.
-- @step setup
CREATE TABLE fj (id int NOT NULL, v nvarchar(10) NULL, d decimal(5,2) NULL, b bit NULL, f float NULL);
INSERT INTO fj VALUES (1, N'a"b', 1.50, 1, 0.5), (2, NULL, NULL, 0, 1e20);
-- @step batch
SELECT id, v, d, b, f FROM fj ORDER BY id FOR JSON PATH;
-- @step batch
SELECT id AS [x.id], v AS [x.v] FROM fj ORDER BY id FOR JSON PATH, INCLUDE_NULL_VALUES;
-- @step batch
SELECT id FROM fj WHERE id = 1 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
-- @step batch
SELECT id, v FROM fj ORDER BY id FOR JSON PATH, ROOT('items');
-- @step batch
SELECT id, v FROM fj ORDER BY id FOR JSON AUTO;
-- @step batch
SELECT id FROM fj WHERE id > 100 FOR JSON PATH;
-- @step batch
SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 5000) AS big FOR JSON PATH;
-- @step batch
SELECT 1 AS a, N'é\/' + NCHAR(1) AS s, CAST('2024-01-02T03:04:05' AS datetime2(0)) AS t, 0x0102 AS bin FOR JSON PATH;
