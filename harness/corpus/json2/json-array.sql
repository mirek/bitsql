-- JSON_ARRAY: ABSENT ON NULL by default, NULL ON NULL keeps nulls; nested
-- JSON values embedded raw.
-- @step batch
SELECT JSON_ARRAY() a, JSON_ARRAY(1, N'x', NULL, 2.5) b, JSON_ARRAY(1, NULL NULL ON NULL) c, JSON_ARRAY(NULL ABSENT ON NULL) d, JSON_ARRAY(JSON_ARRAY(1), JSON_OBJECT('k':'v')) e;
SELECT JSON_ARRAY(CHAR(1)) a, JSON_ARRAY(CAST('x' AS varchar(max))) b;
SELECT JSON_ARRAY(CAST(1 AS bit), CAST(0 AS bit), 1e0, CAST(1.25 AS decimal(5,3)), CAST(2 AS money)) a, JSON_ARRAY(JSON_QUERY(N'[1,2]'), JSON_QUERY(N'{"a":1}', '$.a')) b;
DECLARE @v int = NULL, @w nvarchar(5) = N'q'; SELECT JSON_ARRAY(@v, @w) a, JSON_ARRAY(@v, @w NULL ON NULL) b;
-- @step batch
SELECT JSON_ARRAY(1 ABSENT ON NULL, 2) a;
