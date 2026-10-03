-- WAITFOR DELAY completes with no DONE of its own? (tokens), statements
-- after it run.
-- @step batch
SELECT 1 AS a;
WAITFOR DELAY '00:00:00.050';
SELECT 2 AS b;
-- @step batch
WAITFOR DELAY '00:00:00';
