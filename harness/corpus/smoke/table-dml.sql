-- @step setup
CREATE TABLE t (id int NOT NULL PRIMARY KEY, name nvarchar(20) NULL)
-- @step batch
INSERT INTO t VALUES (1, N'one'), (2, NULL);
UPDATE t SET name = N'two' WHERE id = 2;
DELETE FROM t WHERE id = 3;
SELECT id, name FROM t ORDER BY id
