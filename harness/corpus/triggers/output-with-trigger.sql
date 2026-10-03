-- OUTPUT without INTO is rejected on a table with an enabled trigger (334).
-- @step setup
CREATE TABLE ot (id int PRIMARY KEY);
CREATE TABLE ot_sink (id int);
-- @step setup
CREATE TRIGGER trg_ot ON ot AFTER INSERT AS SET NOCOUNT ON;
-- @step batch
INSERT INTO ot OUTPUT inserted.id VALUES (1);
-- @step batch
INSERT INTO ot OUTPUT inserted.id INTO ot_sink VALUES (2);
SELECT id FROM ot_sink;
