-- SQL Server 2025 feature audit: json.
-- @step batch
DECLARE @j json = '{"a":1}'; SELECT JSON_VALUE(@j, '$.a') AS a; SELECT JSON_ARRAYAGG(v ORDER BY v) AS arr, JSON_OBJECTAGG(k:v) AS obj FROM (VALUES ('a',1),('b',2)) AS t(k,v);
