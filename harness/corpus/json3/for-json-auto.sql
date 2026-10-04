-- FOR JSON AUTO nesting beyond the msduck captures: a self join, a GROUP BY
-- over a join, expressions between source columns, NULL parents, and the
-- batch-level 13600 / 13620 compile errors inside subqueries.
-- @step setup
CREATE TABLE dbo.p (id int NOT NULL PRIMARY KEY, name nvarchar(10) NULL);
CREATE TABLE dbo.c (id int NOT NULL PRIMARY KEY, p_id int NULL, x nvarchar(10) NULL);
INSERT dbo.p VALUES (1, N'one'), (2, NULL), (3, N'three');
INSERT dbo.c VALUES (10, 1, N'a'), (11, 1, NULL), (12, 2, N'b'), (13, NULL, N'z');
-- @step batch
SELECT p.id, p.name, c.x FROM dbo.p p JOIN dbo.c c ON c.p_id = p.id ORDER BY c.id FOR JSON AUTO, INCLUDE_NULL_VALUES
-- @step batch
SELECT p.name, c.x, c.id FROM dbo.c c LEFT JOIN dbo.p p ON p.id = c.p_id ORDER BY c.id FOR JSON AUTO
-- @step batch
SELECT p.id, LEN(p.name) AS n, c.x, UPPER(c.x) AS ux FROM dbo.p p JOIN dbo.c c ON c.p_id = p.id ORDER BY c.id FOR JSON AUTO
-- @step batch
SELECT p1.id, p2.id AS id2 FROM dbo.p p1 JOIN dbo.p p2 ON p2.id = p1.id + 1 ORDER BY p1.id FOR JSON AUTO
-- @step batch
SELECT p.id, COUNT(c.id) AS cnt FROM dbo.p p LEFT JOIN dbo.c c ON c.p_id = p.id GROUP BY p.id ORDER BY p.id FOR JSON AUTO
-- @step batch
SELECT 1 AS k; SELECT (SELECT 2 AS v FOR JSON AUTO) AS j
-- @step batch
SELECT 1 AS k; SELECT (SELECT p.id FROM dbo.p p FOR JSON PATH, ROOT('r'), WITHOUT_ARRAY_WRAPPER) AS j
-- @step batch
SELECT p.id, c.x FROM dbo.p p JOIN dbo.c c ON c.p_id = p.id ORDER BY c.id FOR JSON AUTO, ROOT('rows')
