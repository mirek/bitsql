-- JSON_ARRAYAGG / JSON_OBJECTAGG beyond the msduck captures: NULL handling
-- per clause, JSON text values, the scope ordering shared with STRING_AGG,
-- WITHIN GROUP being ignored, windowed running arrays, and HAVING.
-- @step setup
CREATE TABLE dbo.s (id int NOT NULL PRIMARY KEY, g int NULL, k nvarchar(10) NULL, v int NULL);
INSERT dbo.s VALUES (1, 1, N'b', 2), (2, 1, N'a', NULL), (3, 2, N'c', 3), (4, 2, N'd', 1), (5, NULL, N'e', 5);
-- @step batch
SELECT g, JSON_ARRAYAGG(v) AS a, JSON_ARRAYAGG(v NULL ON NULL) AS an, JSON_OBJECTAGG(k:v) AS o, JSON_OBJECTAGG(k:v ABSENT ON NULL) AS oa FROM dbo.s GROUP BY g ORDER BY g
-- @step batch
SELECT JSON_ARRAYAGG(JSON_QUERY(N'{"x":1}')) AS q, JSON_ARRAYAGG(N'{"x":1}') AS s, JSON_OBJECTAGG(k:JSON_ARRAY(v)) AS o FROM dbo.s WHERE id < 3
-- @step batch
SELECT JSON_ARRAYAGG(k ORDER BY v DESC) AS a, JSON_OBJECTAGG(k:id) AS o FROM dbo.s
-- @step batch
SELECT JSON_ARRAYAGG(k) WITHIN GROUP (ORDER BY v DESC) AS a FROM dbo.s
-- @step batch
SELECT id, JSON_ARRAYAGG(k) OVER (ORDER BY id) AS run, JSON_ARRAYAGG(v) OVER (PARTITION BY g ORDER BY id) AS part FROM dbo.s ORDER BY id
-- @step batch
SELECT g FROM dbo.s GROUP BY g HAVING JSON_ARRAYAGG(v) = N'[3,1]'
-- @step batch
SELECT (SELECT JSON_ARRAYAGG(id ORDER BY id) FROM dbo.s s2 WHERE s2.g = s.g) AS ids, s.id FROM dbo.s s ORDER BY s.id
-- @step batch
SELECT JSON_ARRAYAGG(id ORDER BY id) AS a, STRING_AGG(k, ',') WITHIN GROUP (ORDER BY id) AS b FROM dbo.s
-- @step batch
SELECT JSON_OBJECTAGG(k:v) OVER (ORDER BY id) AS o FROM dbo.s
-- @step batch
SELECT JSON_ARRAYAGG(v ABSENT ON NULL NULL ON NULL) AS a FROM dbo.s
-- @step batch
SELECT JSON_ARRAYAGG() AS a FROM dbo.s
