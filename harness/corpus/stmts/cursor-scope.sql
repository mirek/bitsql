-- Cursor scope and lifetime: LOCAL cursors belong to their batch or
-- module, GLOBAL ones to the session; cursor variables; @@CURSOR_ROWS after
-- CLOSE, DEALLOCATE and the end of a procedure; @@FETCH_STATUS across
-- cursors; cursors survive COMMIT and ROLLBACK.
-- @step setup
CREATE TABLE t (id int NOT NULL PRIMARY KEY, name varchar(10) NOT NULL);
INSERT t VALUES (1,'a'),(2,'b'),(3,'c');
-- @step setup
CREATE PROCEDURE dbo.p_local AS
BEGIN
  DECLARE c CURSOR LOCAL STATIC FOR SELECT id FROM t;
  OPEN c;
  SELECT @@CURSOR_ROWS AS in_proc;
END
-- @step batch
SELECT @@CURSOR_ROWS AS initial_rows, @@FETCH_STATUS AS initial_fs;
EXEC dbo.p_local;
SELECT @@CURSOR_ROWS AS after_proc, CURSOR_STATUS('local', 'c') AS st;
-- @step batch
DECLARE a CURSOR GLOBAL STATIC FOR SELECT id FROM t;
DECLARE b CURSOR GLOBAL STATIC FOR SELECT id FROM t WHERE id = 1;
OPEN a; OPEN b;
SELECT @@CURSOR_ROWS AS rows_b;
CLOSE a;
SELECT @@CURSOR_ROWS AS after_close_a;
FETCH NEXT FROM a;
SELECT @@FETCH_STATUS AS fs_closed;
DEALLOCATE b;
SELECT @@CURSOR_ROWS AS after_dealloc_b;
OPEN a;
FETCH LAST FROM a;
SELECT @@FETCH_STATUS AS fs_last;
-- @step batch
DECLARE @cv CURSOR, @cv2 CURSOR;
SET @cv = a;
SET @cv2 = @cv;
FETCH FIRST FROM @cv2;
DEALLOCATE a;
SELECT CURSOR_STATUS('global', 'a') AS named, CURSOR_STATUS('variable', '@cv') AS v1, CURSOR_STATUS('variable', '@cv2') AS v2, CURSOR_STATUS('variable', '@nope') AS v3;
FETCH NEXT FROM @cv;
DEALLOCATE @cv;
FETCH NEXT FROM @cv2;
CLOSE @cv2;
SELECT CURSOR_STATUS('variable', '@cv2') AS closed_v2;
-- @step batch
DECLARE s CURSOR LOCAL STATIC FOR SELECT id FROM t;
OPEN s;
BEGIN TRAN;
FETCH NEXT FROM s;
ROLLBACK;
FETCH NEXT FROM s;
SELECT CURSOR_STATUS('local', 's') AS st;
