-- Trap: DONE_COUNT presence depends on NOCOUNT; DONEINPROC vs DONE depends on proc context.
-- @step setup
CREATE TABLE dt (x int NOT NULL);
-- @step setup
CREATE PROCEDURE dbo.dt_proc AS BEGIN INSERT INTO dt VALUES (1); SELECT x FROM dt; UPDATE dt SET x = x WHERE 1 = 0; END
-- @step batch
INSERT INTO dt VALUES (0);
SELECT COUNT(*) AS c FROM dt;
EXEC dbo.dt_proc;
-- @step batch
SET NOCOUNT ON;
INSERT INTO dt VALUES (2);
EXEC dbo.dt_proc;
SET NOCOUNT OFF;
-- @step proc dbo.dt_proc
