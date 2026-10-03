-- SET LOCK_TIMEOUT 0: a conflicting request fails at once with 1222; the
-- statement fails but the batch continues.
-- @step setup
CREATE TABLE t (id int PRIMARY KEY, v int);
INSERT t VALUES (1, 1);
-- @step batch
BEGIN TRAN; UPDATE t SET v = 10 WHERE id = 1;
-- @step batch conn=2
SET LOCK_TIMEOUT 0;
UPDATE t SET v = 99 WHERE id = 1;
SELECT @@ERROR AS err, @@TRANCOUNT AS tc;
-- @step batch
COMMIT; SELECT v FROM t;
