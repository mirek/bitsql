-- PIVOT: implicit grouping by every source column not named in the PIVOT
-- clause, value columns named by the IN list as written, aggregate result
-- types, metadata flags (grouping columns keep their own, pivot columns 1),
-- no 8153 warning, output sorted by the grouping columns, joins around
-- PIVOT, nested PIVOT, IN values converted to the pivot column's type.
-- @step setup
CREATE TABLE s (id int NOT NULL PRIMARY KEY, region varchar(10) NOT NULL, yr int NULL, amt decimal(10,2) NULL, qty smallint NOT NULL, note nvarchar(20) NULL, d date NULL, b bit NULL, u uniqueidentifier NULL);
INSERT INTO s (id, region, yr, amt, qty, note, d, b) VALUES (1,'east',2023,10.50,1,N'a','2024-01-01',1),(2,'east',2024,20.00,2,NULL,'2024-01-02',0),(3,'west',2023,NULL,3,N'b',NULL,NULL),(4,'west',2023,5.25,4,N'c','2024-01-01',1),(5,'north',NULL,1.00,5,NULL,NULL,0);
CREATE TABLE w (id int NOT NULL PRIMARY KEY, q1 int NULL, q2 int NULL);
INSERT INTO w VALUES (1,10,NULL),(2,NULL,NULL),(3,7,8);
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) AS src PIVOT (SUM(amt) FOR yr IN ([2023], [2024], [2025])) AS p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) AS src PIVOT (SUM(amt) FOR yr IN ([2023], [2024], [2025])) AS p ORDER BY region DESC;
-- @step batch
SELECT * FROM s PIVOT (SUM(amt) FOR yr IN ([2023], [2024])) AS p ORDER BY id;
-- @step batch
SELECT region, [2023] AS a, [2024] FROM (SELECT region, yr, qty FROM s) src PIVOT (COUNT(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, qty FROM s) src PIVOT (AVG(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, note FROM s) src PIVOT (MAX(note) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (MIN(amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (COUNT_BIG(amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (STDEV(amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, CAST(qty AS money) qty FROM s) src PIVOT (AVG(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, CAST(qty AS real) qty FROM s) src PIVOT (SUM(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, CAST(qty AS bigint) qty FROM s) src PIVOT (VAR(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, CAST(qty AS tinyint) qty FROM s) src PIVOT (SUM(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, qty FROM s) src PIVOT (count(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR region IN ([east], [west], [nope])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR region IN (east, [West], [EAST ])) p;
-- @step batch
SELECT * FROM (SELECT region, d, amt FROM s) src PIVOT (SUM(amt) FOR d IN ([2024-01-01], [20240102])) p;
-- @step batch
SELECT * FROM (SELECT region, b, amt FROM s) src PIVOT (SUM(amt) FOR b IN ([1], [0], [true])) p;
-- @step batch
SELECT * FROM (SELECT region, CAST(yr AS varchar(10)) yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023], [ 2024])) p;
-- @step batch
SELECT p.region, p.[2023] FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) p WHERE p.[2023] > 1;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) p JOIN s ON s.region = p.region ORDER BY s.id;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) p, w ORDER BY p.region, w.id;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(src.amt) FOR src.yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) p PIVOT (SUM([2023]) FOR region IN ([east])) q;
-- @step batch
WITH c AS (SELECT region, yr, qty FROM s) SELECT * FROM c PIVOT (SUM(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) p FOR JSON PATH;
-- @step batch
SELECT * FROM (SELECT id % 2 AS k, region, yr, qty FROM s) src PIVOT (SUM(qty) FOR yr IN ([2023], [2024])) p ORDER BY k, region;
-- @step batch
SELECT * FROM (SELECT region, id % 2 AS k, yr, qty FROM s) src PIVOT (SUM(qty) FOR yr IN ([2023], [2024])) p ORDER BY region DESC, k;
-- @step batch
SELECT * FROM (SELECT region, yr, u FROM s) src PIVOT (MAX(u) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (VALUES (1, 'a', 5), (1, 'b', 6), (2, 'a', 7)) v(k, c, n) PIVOT (SUM(n) FOR c IN ([a], [b])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, qty FROM s) src PIVOT (SUM(qty) FOR yr IN ([2023])) p WHERE 1 = 0;
-- @step batch
SELECT * FROM (SELECT yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT yr, amt FROM s WHERE 1 = 0) src PIVOT (SUM(amt) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, qty FROM s) src PIVOT (APPROX_COUNT_DISTINCT(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT id % 2 AS k, region, id % 3 AS m, yr, qty FROM s) src PIVOT (SUM(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM (SELECT id % 3 AS m, id % 2 AS k, region, yr, qty FROM s) src PIVOT (MAX(qty) FOR yr IN ([2023], [2024])) p;
-- @step batch
SELECT * FROM s a JOIN w b ON a.id = b.id PIVOT (SUM(amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT p.* FROM (SELECT s.region, s.yr, s.qty, w.q1 FROM s JOIN w ON s.id = w.id) src PIVOT (SUM(qty) FOR yr IN ([2023], [2024])) AS p ORDER BY region;
