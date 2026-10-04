-- OPEN and FETCH of a missing cursor (16916) report the line of the
-- previous statement that set the current line (0 at the start of a batch
-- or module); CLOSE and DEALLOCATE report their own line. A DECLARE without
-- initializer does not set the line.
-- @step batch
SELECT 1 AS x;

FETCH NEXT FROM nope;
SELECT 2 AS y;
OPEN nope2;
-- @step batch


OPEN nope3;
-- @step batch
SELECT 1 AS x;
CLOSE nope4;
DEALLOCATE nope5;
-- @step batch
DECLARE @a int;
DECLARE @cv CURSOR;
OPEN @cv;
FETCH NEXT FROM nope6;
-- @step batch
DECLARE c_l CURSOR LOCAL FOR SELECT 1 AS one;

FETCH NEXT FROM nope7;
DEALLOCATE c_l;
