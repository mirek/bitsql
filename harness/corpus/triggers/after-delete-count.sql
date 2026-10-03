-- AFTER DELETE trigger without NOCOUNT: inner statement completions are visible.
-- @step setup
CREATE TABLE d1 (id int PRIMARY KEY);
CREATE TABLE d1_gone (id int);
INSERT INTO d1 VALUES (1), (2), (3);
-- @step setup
CREATE TRIGGER trg_d1_del ON d1 AFTER DELETE AS
  INSERT INTO d1_gone SELECT id FROM deleted;
-- @step batch
DELETE FROM d1 WHERE id >= 2;
SELECT @@ROWCOUNT AS rc;
SELECT id FROM d1_gone ORDER BY id;
