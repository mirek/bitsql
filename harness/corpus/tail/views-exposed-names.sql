-- FROM items of one query level must have distinct exposed names: two
-- tables 1013 (later one first), two correlation names 1011, a correlation
-- name and a table 1012. Checked after objects resolve (208 wins) and
-- before the select list (1013 before 207). Unaliased table functions and
-- the source of a PIVOT take no part.
-- @step setup
CREATE TABLE dbo.t(a int); CREATE TABLE dbo.u(a int);
EXEC('CREATE SCHEMA other');
-- @step setup
CREATE TABLE other.t(a int);
-- @step batch
SELECT 1 FROM dbo.t CROSS JOIN other.t
-- @step batch
SELECT 1 FROM t, t
-- @step batch
SELECT 1 FROM dbo.t JOIN t ON 1=1
-- @step batch
SELECT 1 FROM dbo.t x JOIN dbo.u X ON 1=1
-- @step batch
SELECT 1 FROM dbo.t CROSS JOIN (SELECT 1 a) t
-- @step batch
SELECT 1 FROM dbo.t a CROSS JOIN dbo.u, dbo.u
-- @step batch
UPDATE dbo.t SET a = 1 FROM dbo.t CROSS JOIN other.t
-- @step batch
SELECT 1 FROM missing, missing
-- @step batch
SELECT 1 FROM dbo.t JOIN (dbo.u t JOIN dbo.u ON 1=1) ON 1=1
-- @step batch
SELECT 1 FROM STRING_SPLIT('a', ',') CROSS JOIN STRING_SPLIT('a', ',')
-- @step batch
SELECT 1 FROM dbo.t CROSS APPLY (SELECT 1 a) t
-- @step batch
SELECT 1 FROM dbo.t, dbo.u, missing
-- @step batch
SELECT nope FROM dbo.t, dbo.t
-- @step batch
SELECT 1 FROM (SELECT 1 a) d CROSS JOIN (SELECT 2 a) D
-- @step batch
DECLARE @t TABLE(a int); SELECT 1 FROM @t CROSS JOIN @t
-- @step batch
DECLARE @t TABLE(a int); SELECT 1 FROM @t t CROSS JOIN dbo.t
-- @step batch
SELECT 1 FROM dbo.t PIVOT (MAX(a) FOR a IN ([1])) t
-- @step batch
SELECT (SELECT COUNT(*) FROM dbo.t) FROM dbo.t
