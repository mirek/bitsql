-- An INSERT of a key another transaction inserted (uncommitted) waits, then
-- fails with 2627 after that transaction commits.
-- @step setup
CREATE TABLE k (id int CONSTRAINT pk_k PRIMARY KEY, v int);
-- @step batch
BEGIN TRAN; INSERT k VALUES (5, 1);
-- @step batch conn=2 async
INSERT k VALUES (5, 2);
-- @step batch
COMMIT;
-- @step await conn=2
-- @step batch
SELECT id, v FROM k;
