-- PIVOT over text columns: non-comparable grouping and pivot columns
-- (488) and COUNT of text (8117). bitsql has no text type yet, so these
-- stay visible as unsupported.
-- @step setup
CREATE TABLE s (id int NOT NULL PRIMARY KEY, region varchar(10) NOT NULL, yr int NULL, amt decimal(10,2) NULL, t text NULL);
-- @step batch
SELECT * FROM (SELECT t, yr, amt FROM s) src PIVOT (SUM(amt) FOR yr IN ([2023])) p;
-- @step batch
SELECT * FROM (SELECT region, t, amt FROM s) src PIVOT (SUM(amt) FOR t IN ([a])) p;
-- @step batch
SELECT * FROM (SELECT region, yr, t FROM s) src PIVOT (COUNT(t) FOR yr IN ([2023])) p;
