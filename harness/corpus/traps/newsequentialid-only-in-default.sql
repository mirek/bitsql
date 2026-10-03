-- Trap: NEWSEQUENTIALID() is only valid in a DEFAULT constraint.
-- @step setup
CREATE TABLE seq (n int NOT NULL, id uniqueidentifier NOT NULL CONSTRAINT df_seq_id DEFAULT NEWSEQUENTIALID());
-- @step batch
INSERT INTO seq (n) VALUES (1);
INSERT INTO seq (n) VALUES (2);
SELECT CASE WHEN (SELECT id FROM seq WHERE n = 2) > (SELECT id FROM seq WHERE n = 1) THEN 1 ELSE 0 END AS increasing;
-- @step batch
SELECT NEWSEQUENTIALID() AS direct;
