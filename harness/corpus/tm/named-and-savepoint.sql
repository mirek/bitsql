-- Named TM transaction, TM SAVE and TM ROLLBACK to the savepoint.
-- @step setup
CREATE TABLE t (id int CONSTRAINT pk_t PRIMARY KEY, v int);
-- @step tm begin read_committed outer_tx
-- @step batch
INSERT t VALUES (1, 1);
-- @step tm save sp1
-- @step batch
INSERT t VALUES (2, 2);
-- @step tm rollback sp1
-- @step batch
SELECT @@TRANCOUNT AS tc, COUNT(*) AS n FROM t;
-- @step tm commit
-- @step batch
SELECT @@TRANCOUNT AS tc, COUNT(*) AS n FROM t;
