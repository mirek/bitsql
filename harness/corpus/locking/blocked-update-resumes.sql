-- Connection 2's UPDATE blocks on connection 1's uncommitted UPDATE of the
-- same row, then runs after COMMIT and sees the committed value.
-- @step setup
CREATE TABLE t (id int PRIMARY KEY, v int);
INSERT t VALUES (1, 1), (2, 2);
-- @step batch
BEGIN TRAN; UPDATE t SET v = 10 WHERE id = 1;
-- @step batch conn=2 async
UPDATE t SET v = v + 1 WHERE id = 1; SELECT v FROM t WHERE id = 1;
-- @step batch
UPDATE t SET v = 20 WHERE id = 2;
COMMIT;
-- @step await conn=2
-- @step batch
SELECT id, v FROM t ORDER BY id;
