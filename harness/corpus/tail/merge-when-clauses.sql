-- MERGE WHEN clauses: a repeated action within one WHEN kind is 10714
-- (class 15), a clause after one without a search condition 5324; both
-- fail the whole batch.
-- @step setup
CREATE TABLE mt(id int PRIMARY KEY, n int); INSERT INTO mt VALUES (1, 10);
-- @step batch
MERGE mt AS t USING (VALUES (1,11)) AS s(id,n) ON t.id=s.id WHEN NOT MATCHED BY SOURCE THEN DELETE WHEN NOT MATCHED BY SOURCE AND t.n > 0 THEN UPDATE SET n = 1;
-- @step batch
MERGE mt AS t USING (VALUES (1,11)) AS s(id,n) ON t.id=s.id WHEN NOT MATCHED BY SOURCE AND t.n > 0 THEN DELETE WHEN NOT MATCHED BY SOURCE THEN DELETE;
-- @step batch
MERGE mt AS t USING (VALUES (1,11)) AS s(id,n) ON t.id=s.id WHEN MATCHED AND s.n > 0 THEN DELETE WHEN MATCHED AND s.n > 1 THEN DELETE;
-- @step batch
MERGE mt AS t USING (VALUES (1,11)) AS s(id,n) ON t.id=s.id WHEN MATCHED AND s.n > 0 THEN DELETE WHEN MATCHED AND s.n > 1 THEN UPDATE SET n = 1 WHEN MATCHED THEN UPDATE SET n = 2;
-- @step batch
MERGE mt AS t USING (VALUES (1,11)) AS s(id,n) ON t.id=s.id WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.n) WHEN NOT MATCHED AND s.n > 0 THEN INSERT VALUES (s.id, s.n);
-- @step batch
SELECT 1 AS a; MERGE mt AS t USING (VALUES (1,11)) AS s(id,n) ON t.id=s.id WHEN MATCHED THEN UPDATE SET n=s.n WHEN MATCHED AND s.n>0 THEN DELETE;
-- @step batch
MERGE mt AS t USING (VALUES (1,11)) AS s(id,n) ON t.id=s.id WHEN MATCHED THEN DELETE WHEN MATCHED THEN DELETE;
