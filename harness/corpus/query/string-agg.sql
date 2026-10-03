-- STRING_AGG metadata and ordering (WITHIN GROUP), NULL skipping, empty input.
-- @step setup
CREATE TABLE sa (g int NOT NULL, v varchar(10) NULL, w nvarchar(10) NULL, x varchar(max) NULL, i int NULL);
INSERT INTO sa VALUES (1, 'b', N'β', 'xx', 2), (1, 'a', N'α', NULL, 1), (2, NULL, NULL, NULL, NULL), (2, 'c', N'γ', 'yy', 3);
-- @step batch
SELECT g, STRING_AGG(v, ',') WITHIN GROUP (ORDER BY v) AS sv, STRING_AGG(w, N';') WITHIN GROUP (ORDER BY w DESC) AS sw FROM sa GROUP BY g ORDER BY g;
-- @step batch
SELECT STRING_AGG(x, '-') AS sx, STRING_AGG(i, ',') WITHIN GROUP (ORDER BY i) AS si FROM sa;
-- @step batch
SELECT STRING_AGG(v, ',') AS e FROM sa WHERE g > 10;
-- @step batch
SELECT STRING_AGG(CAST(v AS varchar(max)), ',') WITHIN GROUP (ORDER BY g, v) AS m FROM sa;
