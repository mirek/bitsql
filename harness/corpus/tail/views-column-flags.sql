-- Columns read through a view: every column that is not computed reports
-- as a base column (0x08), also aggregates, UNION, window and derived-table
-- columns; computed expressions keep fComputed. Derived tables and CTEs do not.
-- @step setup
CREATE TABLE s(id INT NOT NULL, g INT, v INT, n NVARCHAR(20) NOT NULL);
INSERT INTO s VALUES (1,1,1,N'a');
-- @step setup
CREATE VIEW v1 AS SELECT MIN(v) AS mn, COUNT(*) AS c, g, g+1 AS g1, 5 AS lit FROM s GROUP BY g
-- @step setup
CREATE VIEW v2 AS SELECT id, v FROM s UNION SELECT id, v FROM s
-- @step setup
CREATE VIEW v3 AS SELECT d.x, d.y, ROW_NUMBER() OVER (ORDER BY id) AS rn FROM (SELECT id, id+1 AS x, MAX(v) OVER () AS y FROM s) d
-- @step setup
CREATE VIEW v4 AS SELECT j.[key], j.[value], j.[type], ss.value AS sv FROM s CROSS APPLY OPENJSON(N'{"a":1}') j CROSS APPLY STRING_SPLIT(n, N',') ss
-- @step batch
SELECT * FROM v1
-- @step batch
SELECT * FROM v2
-- @step batch
SELECT * FROM v3
-- @step batch
SELECT * FROM v4
-- @step batch
SELECT d.mn FROM (SELECT MIN(v) AS mn FROM s) d
-- @step batch
WITH c AS (SELECT MIN(v) AS mn FROM s) SELECT mn FROM c
