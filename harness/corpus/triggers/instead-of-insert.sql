-- INSTEAD OF INSERT trigger replaces the insert.
-- @step setup
CREATE TABLE io (id int PRIMARY KEY, v varchar(10));
-- @step setup
CREATE TRIGGER trg_io ON io INSTEAD OF INSERT AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO io (id, v) SELECT id * 10, UPPER(v) FROM inserted;
END
-- @step batch
INSERT INTO io VALUES (1, 'a'), (2, 'b');
SELECT @@ROWCOUNT AS rc;
SELECT id, v FROM io ORDER BY id;
