-- Trap: identity values are not rolled back with the transaction; gaps are expected.
-- @step setup
CREATE TABLE ident (id int IDENTITY(10, 5) NOT NULL PRIMARY KEY, v varchar(10) NOT NULL);
-- @step batch
INSERT INTO ident (v) VALUES ('first');
BEGIN TRANSACTION;
INSERT INTO ident (v) VALUES ('rolled');
ROLLBACK;
INSERT INTO ident (v) VALUES ('second');
SELECT id, v FROM ident ORDER BY id;
SELECT SCOPE_IDENTITY() AS scope_identity, @@IDENTITY AS at_identity, IDENT_CURRENT('ident') AS ident_current;
