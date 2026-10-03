-- Trap: default *_CI_AS collation is case-insensitive and = ignores trailing spaces.
-- @step setup
CREATE TABLE names (id int NOT NULL PRIMARY KEY, n varchar(20) NOT NULL, w nvarchar(20) NOT NULL);
INSERT INTO names VALUES (1, 'abc', N'abc'), (2, 'ABC  ', N'ABC  '), (3, 'abd', N'abd');
-- @step batch
SELECT CASE WHEN 'abc' = 'ABC' THEN 1 ELSE 0 END AS ci_eq,
       CASE WHEN N'abc' = N'abc   ' THEN 1 ELSE 0 END AS trailing_eq,
       CASE WHEN N'abc' LIKE N'abc   ' THEN 1 ELSE 0 END AS trailing_like,
       CASE WHEN N'  abc' = N'abc' THEN 1 ELSE 0 END AS leading_eq,
       LEN(N'abc   ') AS len_trailing, DATALENGTH(N'abc   ') AS datalength_trailing;
SELECT id FROM names WHERE n = 'abc' ORDER BY id;
SELECT id FROM names WHERE w = N'ABC' ORDER BY id;
SELECT COUNT(DISTINCT n) AS distinct_n, COUNT(DISTINCT w) AS distinct_w FROM names;
SELECT n, COUNT(*) AS c FROM names GROUP BY n ORDER BY n;
