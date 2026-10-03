-- ROLLBACK inside a trigger ends the batch with 3609 and undoes the statement.
-- @step setup
CREATE TABLE rb (id int PRIMARY KEY);
-- @step setup
CREATE TRIGGER trg_rb ON rb AFTER INSERT AS
BEGIN
  IF EXISTS (SELECT 1 FROM inserted WHERE id < 0)
  BEGIN
    RAISERROR('negative ids are not allowed', 16, 1);
    ROLLBACK TRANSACTION;
  END
END
-- @step batch
INSERT INTO rb VALUES (1);
INSERT INTO rb VALUES (-1);
SELECT 'not reached' AS r;
-- @step batch
SELECT id FROM rb ORDER BY id;
SELECT @@TRANCOUNT AS tc;
