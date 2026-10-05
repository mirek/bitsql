-- A WITH whose SELECT never references a CTE: 422 for the whole batch only
-- when the SELECT is a bare constant projection (no FROM, WHERE, TOP,
-- DISTINCT, ORDER BY, subquery or aggregate); unused CTEs are fine otherwise.
-- @step batch
SELECT 1 AS before_;
WITH r AS (SELECT 1 AS id) SELECT 7 AS x;
-- @step batch
DECLARE @k int;
WITH r AS (SELECT 1 AS id) SELECT @k = 7;
-- @step batch
CREATE PROCEDURE dbo.p AS BEGIN DECLARE @k int; WITH r AS (SELECT 1 AS id) SELECT @k = 7; END;
-- @step batch
DECLARE @k int;
WITH r AS (SELECT 1 AS id) SELECT @k = 7 WHERE 1 = 1;
SELECT @k AS k;
-- @step batch
DECLARE @k int;
WITH r AS (SELECT 1 AS id) SELECT @k = (SELECT 2);
SELECT @k AS k;
-- @step batch
DECLARE @k int;
WITH r AS (SELECT 1 AS id) SELECT @k = (SELECT id FROM r);
SELECT @k AS k;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT 7 AS x WHERE 1 = 1;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT (SELECT 3) AS x;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT 7 AS x UNION ALL SELECT 8;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT 7 AS x ORDER BY x;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT TOP 1 7 AS x;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT DISTINCT 7 AS x;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT COUNT(*) AS x;
-- @step batch
WITH r AS (SELECT 1 AS id) SELECT 7 AS x FROM (VALUES (1)) v(a);
-- @step batch
DECLARE @k int;
WITH r AS (SELECT 1 AS id) SELECT @k = 7 WHERE EXISTS (SELECT 1);
SELECT @k AS k;
-- @step batch
DECLARE @k int;
WITH r AS (SELECT 1 AS id), q AS (SELECT 2 AS id) SELECT @k = id FROM r;
SELECT @k AS k;
-- @step batch
DECLARE @k int = 3;
WITH r AS (SELECT 1 AS id) SELECT @k + 1 AS x, CASE WHEN @k > 1 THEN 'a' END AS y;
