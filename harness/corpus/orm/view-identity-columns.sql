-- A view column over an identity column: sys.columns.is_identity and
-- COLUMNPROPERTY IsIdentity are 1, sys.identity_columns lists it with NULL
-- seed/increment, IDENT_SEED of the view is the table's. Not emulated yet.
-- @step setup
CREATE TABLE u (id int IDENTITY(5,2) PRIMARY KEY, n int);
-- @step setup
CREATE VIEW vu AS SELECT id, n, id + 0 AS id2 FROM u;
-- @step batch
SELECT name, is_identity FROM sys.columns WHERE object_id = OBJECT_ID('vu') ORDER BY column_id;
SELECT OBJECT_NAME(object_id) AS o, name, seed_value, increment_value FROM sys.identity_columns WHERE object_id IN (OBJECT_ID('u'), OBJECT_ID('vu')) ORDER BY o;
SELECT COLUMNPROPERTY(OBJECT_ID('vu'), 'id', 'IsIdentity') AS a, COLUMNPROPERTY(OBJECT_ID('vu'), 'id2', 'IsIdentity') AS b, IDENT_SEED('vu') AS s;
