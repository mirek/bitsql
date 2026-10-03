-- AFTER UPDATE trigger: UPDATE(col), inserted/deleted join, NOCOUNT inside the trigger.
-- @step setup
CREATE TABLE acct (id int PRIMARY KEY, bal int NOT NULL, note varchar(20) NULL);
CREATE TABLE acct_log (id int, old_bal int, new_bal int, bal_changed bit);
INSERT INTO acct VALUES (1, 100, NULL), (2, 200, NULL);
-- @step setup
CREATE TRIGGER trg_acct_upd ON acct AFTER UPDATE AS
BEGIN
  SET NOCOUNT ON;
  INSERT INTO acct_log SELECT d.id, d.bal, i.bal, CASE WHEN UPDATE(bal) THEN 1 ELSE 0 END
  FROM deleted d JOIN inserted i ON i.id = d.id;
END
-- @step batch
UPDATE acct SET bal = bal + 5 WHERE id = 1;
UPDATE acct SET note = 'x';
SELECT id, old_bal, new_bal, bal_changed FROM acct_log ORDER BY id, new_bal;
