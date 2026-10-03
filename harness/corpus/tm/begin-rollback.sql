-- TM ROLLBACK undoes the work.
-- @step setup
CREATE TABLE t (id int CONSTRAINT pk_t PRIMARY KEY, v int);
-- @step tm begin read_committed
-- @step batch
INSERT t VALUES (1, 1);
-- @step tm rollback
-- @step batch
SELECT @@TRANCOUNT AS tc, COUNT(*) AS n FROM t;
