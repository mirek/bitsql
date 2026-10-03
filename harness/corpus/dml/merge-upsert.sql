-- MERGE: matched update, not-matched insert, not-matched-by-source delete, OUTPUT $action.
-- @step setup
CREATE TABLE mt (id int NOT NULL PRIMARY KEY, n int NULL);
INSERT INTO mt VALUES (1, 10), (2, 20), (3, 30);
-- @step batch
MERGE mt AS t
USING (VALUES (1, 11), (4, 40)) AS s(id, n)
ON t.id = s.id
WHEN MATCHED THEN UPDATE SET n = s.n
WHEN NOT MATCHED THEN INSERT (id, n) VALUES (s.id, s.n)
WHEN NOT MATCHED BY SOURCE AND t.id = 3 THEN DELETE
OUTPUT $action AS action, inserted.id AS new_id, deleted.n AS old_n, inserted.n AS new_n;
SELECT @@ROWCOUNT AS affected;
SELECT id, n FROM mt ORDER BY id;
