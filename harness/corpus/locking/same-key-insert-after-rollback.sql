-- The waiting INSERT succeeds when the other transaction rolls back.
-- @step setup
CREATE TABLE k (id int PRIMARY KEY, v int);
-- @step batch
BEGIN TRAN; INSERT k VALUES (5, 1);
-- @step batch conn=2 async
INSERT k VALUES (5, 2);
-- @step batch
ROLLBACK;
-- @step await conn=2
-- @step batch
SELECT id, v FROM k;
