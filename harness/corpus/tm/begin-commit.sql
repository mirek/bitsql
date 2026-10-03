-- TDS transaction manager requests (tedious beginTransaction / mssql
-- Transaction.begin): BEGIN with READ_COMMITTED, work over RPC, COMMIT.
-- @step setup
CREATE TABLE t (id int CONSTRAINT pk_t PRIMARY KEY, v int);
-- @step tm begin read_committed
-- @step rpc
INSERT t VALUES (1, 1); SELECT @@TRANCOUNT AS tc;
-- @step tm commit
-- @step batch
SELECT @@TRANCOUNT AS tc, COUNT(*) AS n FROM t;
