-- A row lock does not block writes to other rows of the same table.
-- @step setup
CREATE TABLE t (id int PRIMARY KEY, v int);
INSERT t VALUES (1, 1), (2, 2);
-- @step batch
BEGIN TRAN; UPDATE t SET v = 10 WHERE id = 1;
-- @step batch conn=2
UPDATE t SET v = 20 WHERE id = 2; SELECT @@ROWCOUNT AS rc;
-- @step batch
COMMIT; SELECT id, v FROM t ORDER BY id;
