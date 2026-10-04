-- DML target table hints and MERGE compile errors: unknown hints are 321,
-- NOLOCK/READUNCOMMITTED on a target 1065 (reported at line 15) and fail the
-- whole batch; MERGE INSERT value counts (109/110/213), TOP PERCENT through
-- variables (1031/1014 end the batch), TOP (NULL) 1060.
-- @step setup
CREATE TABLE t (id int PRIMARY KEY, n int);
-- @step batch
UPDATE t WITH (NOLOCK) SET n = 1;
-- @step batch
SELECT 1 AS first_statement;
INSERT t WITH (READUNCOMMITTED) VALUES (1, 1);
-- @step batch
DELETE t WITH (bogus);
-- @step batch
SELECT 1 AS first_statement;
MERGE t WITH (NOLOCK) AS x USING (VALUES (1)) s(id) ON x.id = s.id WHEN MATCHED THEN DELETE;
SELECT 2 AS after_merge;
-- @step batch
MERGE t WITH (bogus) AS x USING (VALUES (1)) s(id) ON x.id = s.id WHEN MATCHED THEN DELETE;
SELECT 2 AS after_merge;
-- @step batch
MERGE t AS x USING (VALUES (1, 2)) s(id, n) ON x.id = s.id WHEN NOT MATCHED THEN INSERT (id, n) VALUES (s.id, s.n, 1);
-- @step batch
MERGE t AS x USING (VALUES (1, 2)) s(id, n) ON x.id = s.id WHEN NOT MATCHED THEN INSERT VALUES (s.id);
-- @step batch
DECLARE @p int = 101;
MERGE TOP (@p) PERCENT t AS x USING (VALUES (1, 2)) s(id, n) ON x.id = s.id WHEN NOT MATCHED THEN INSERT VALUES (s.id, 1);
SELECT 5 AS after_merge;
-- @step batch
DECLARE @p int = NULL;
MERGE TOP (@p) PERCENT t AS x USING (VALUES (1, 2)) s(id, n) ON x.id = s.id WHEN NOT MATCHED THEN INSERT VALUES (s.id, 1);
SELECT 5 AS after_merge;
-- @step batch
DECLARE @p decimal(5, 2) = 50.5;
MERGE TOP (@p) PERCENT t AS x USING (VALUES (1, 2), (2, 2), (3, 2)) s(id, n) ON x.id = s.id WHEN NOT MATCHED THEN INSERT VALUES (s.id, 1);
SELECT id FROM t ORDER BY id;
