-- MERGE: a target row matched by two source rows with UPDATE fails with 8672.
-- @step setup
CREATE TABLE mr (id int NOT NULL PRIMARY KEY, n int NULL);
INSERT INTO mr VALUES (1, 10);
-- @step batch
MERGE mr AS t USING (VALUES (1, 11), (1, 12)) AS s(id, n) ON t.id = s.id
WHEN MATCHED THEN UPDATE SET n = s.n;
SELECT n FROM mr;
