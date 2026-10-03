-- A trigger inserting into another table with a trigger (nested), TRIGGER_NESTLEVEL.
-- @step setup
CREATE TABLE n1 (id int PRIMARY KEY);
CREATE TABLE n2 (id int PRIMARY KEY);
CREATE TABLE nlog (src varchar(5), lvl int);
-- @step setup
CREATE TRIGGER trg_n1 ON n1 AFTER INSERT AS BEGIN SET NOCOUNT ON; INSERT INTO nlog VALUES ('n1', TRIGGER_NESTLEVEL()); INSERT INTO n2 SELECT id FROM inserted; END
-- @step setup
CREATE TRIGGER trg_n2 ON n2 AFTER INSERT AS BEGIN SET NOCOUNT ON; INSERT INTO nlog VALUES ('n2', TRIGGER_NESTLEVEL()); END
-- @step batch
INSERT INTO n1 VALUES (7);
SELECT src, lvl FROM nlog ORDER BY src;
SELECT id FROM n2;
