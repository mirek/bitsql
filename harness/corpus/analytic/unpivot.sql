-- UNPIVOT: NULL values dropped, rows per source row in IN-list order, the
-- name column is nvarchar(128) nullable holding the source column's own
-- spelling, value column type and nullability from the IN columns, output
-- column order (remaining columns, value, name), errors 8167, 277, 265,
-- 8156, 207, 4104.
-- @step setup
CREATE TABLE w (id int NOT NULL PRIMARY KEY, q1 int NULL, q2 int NULL, q3 int NOT NULL, q4 int NOT NULL, s1 varchar(5) NULL, s2 varchar(10) NULL, n1 nvarchar(5) NULL, d1 decimal(5,2) NULL, d2 decimal(6,2) NULL);
INSERT INTO w (id, q1, q2, q3, q4, s1, s2, n1, d1, d2) VALUES (1,10,NULL,30,31,'a','bb',N'x',1.5,2.5),(2,NULL,NULL,5,6,NULL,'c',NULL,NULL,3.25),(3,7,8,9,10,'d',NULL,N'y',4,5);
-- @step batch
SELECT * FROM w UNPIVOT (val FOR qtr IN (q1, q2, q3)) AS u ORDER BY id, qtr;
-- @step batch
SELECT id, qtr, val FROM (SELECT id, q1, q2, q3 FROM w) src UNPIVOT (val FOR qtr IN (q1, q2, q3)) u;
-- @step batch
SELECT id, qtr, val FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (val FOR qtr IN ([q2], [q1])) u;
-- @step batch
SELECT id, qtr, val FROM (SELECT id, q3, q4 FROM w) src UNPIVOT (val FOR qtr IN (q3, q4)) u;
-- @step batch
SELECT * FROM w UNPIVOT (v FOR k IN (Q1, [Q2])) u;
-- @step batch
SELECT id, k, v FROM (SELECT id, CAST(s1 AS varchar(10)) s1, s2 FROM w) src UNPIVOT (v FOR k IN (s1, s2)) u;
-- @step batch
SELECT * FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR k IN (q1, q2)) u WHERE k = 'Q1';
-- @step batch
SELECT * FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR k IN (q1)) u;
-- @step batch
SELECT * FROM (SELECT id, CAST('a' AS varchar(max)) a, CAST('b' AS varchar(max)) b FROM w) src UNPIVOT (v FOR k IN (a, b)) u;
-- @step batch
SELECT * FROM (SELECT 1 AS id, 2 AS a, 3 AS b) src UNPIVOT (v FOR k IN (a, b)) u;
-- @step batch
SELECT * FROM (SELECT 1 AS id, 2 AS [A b], 3 AS [ü]) src UNPIVOT (v FOR k IN ([A b], [ü])) u;
-- @step batch
SELECT * FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR k IN (q1, q2)) u UNPIVOT (v2 FOR k2 IN (id)) u2;
-- @step batch
SELECT u.* FROM w UNPIVOT (v FOR k IN (q1, q2)) u;
-- @step batch
SELECT * FROM w AS ww UNPIVOT (v FOR k IN (q1, q2)) u CROSS JOIN (SELECT 1 z) zz;
-- @step batch
SELECT k, COUNT(*) AS n, SUM(v) AS s FROM w UNPIVOT (v FOR k IN (q1, q2, q3)) u GROUP BY k ORDER BY k;
-- @step batch
SELECT * FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR k IN (q1, q2)) u PIVOT (MAX(v) FOR k IN ([q1], [q2])) p;
-- @step batch
SELECT id, k, v FROM (SELECT id, s1, s2 FROM w) src UNPIVOT (v FOR k IN (s1, s2)) u;
-- @step batch
SELECT id, k, v FROM (SELECT id, s1, n1 FROM w) src UNPIVOT (v FOR k IN (s1, n1)) u;
-- @step batch
SELECT id, k, v FROM (SELECT id, d1, d2 FROM w) src UNPIVOT (v FOR k IN (d1, d2)) u;
-- @step batch
SELECT id, k, v FROM (SELECT id, q1, d2 FROM w) src UNPIVOT (v FOR k IN (q1, d2)) u;
-- @step batch
SELECT * FROM (SELECT id, CAST(N'a' AS nvarchar(5)) COLLATE Latin1_General_BIN2 a, CAST(N'b' AS nvarchar(5)) b FROM w) src UNPIVOT (v FOR k IN (a, b)) u;
-- @step batch
SELECT id, k, v FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR k IN (q1, q1)) u;
-- @step batch
SELECT id, k, v FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR k IN (q1, nope)) u;
-- @step batch
SELECT * FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (id FOR k IN (q1, q2)) u;
-- @step batch
SELECT * FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR id IN (q1, q2)) u;
-- @step batch
SELECT * FROM (SELECT id, q1, q2 FROM w) src UNPIVOT (v FOR v IN (q1, q2)) u;
-- @step batch
SELECT w.id FROM w UNPIVOT (v FOR k IN (q1, q2)) u;
-- @step batch
SELECT * FROM w UNPIVOT (v FOR k IN ()) u;
-- @step batch
SELECT * FROM w UNPIVOT (v FOR k IN (q1)) ;
