-- MERGE: matched delete with condition, insert using defaults and identity.
-- @step setup
CREATE TABLE md (id int IDENTITY(1,1) PRIMARY KEY, k varchar(10) NOT NULL UNIQUE, v int NOT NULL DEFAULT 7);
INSERT INTO md (k, v) VALUES ('a', 1), ('b', 2);
-- @step batch
MERGE INTO md AS t
USING (VALUES ('a'), ('c')) AS s(k)
ON t.k = s.k
WHEN MATCHED AND t.v = 1 THEN DELETE
WHEN NOT MATCHED BY TARGET THEN INSERT (k) VALUES (s.k);
SELECT id, k, v FROM md ORDER BY id;
SELECT SCOPE_IDENTITY() AS si;
