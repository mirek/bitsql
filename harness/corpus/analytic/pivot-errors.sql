-- PIVOT errors: duplicate value columns (8156), a value column named like
-- a grouping column (265 + 8156), unconvertible IN values (8114 + 473),
-- unknown columns (207),
-- invalid aggregates (195, 406, 8117), syntax errors.
-- @step setup
CREATE TABLE s (id int NOT NULL PRIMARY KEY, region varchar(10) NOT NULL, yr int NULL, amt decimal(10,2) NULL, qty smallint NOT NULL, note nvarchar(20) NULL);
INSERT INTO s (id, region, yr, amt, qty, note) VALUES (1,'east',2023,10.50,1,N'a'),(2,'east',2024,20.00,2,NULL);
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR region IN ([east], [east])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR region IN ([east], [EAST])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR region IN ([yr])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([abc])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023.5])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([NULL])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, note FROM s) src PIVOT (SUM(note) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(nope) FOR region IN ([east])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR nope IN ([east])) p;
-- @step batch
SELECT src.region FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (LEN(amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, qty FROM s) src PIVOT (GROUPING(qty) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, CHECKSUM(qty) qty FROM s) src PIVOT (CHECKSUM_AGG(qty) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, note FROM s) src PIVOT (COUNT(*) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt, qty FROM s) src PIVOT (SUM(amt), SUM(qty) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt + 1) FOR region IN ([east])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR region IN ([east]));
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (STRING_AGG(amt, ',') FOR region IN ([east])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(DISTINCT amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) AS p (a, b);
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ()) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN (2023)) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ('2023')) p;
-- @step batch
SELECT * FROM (SELECT region, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023]) p;
