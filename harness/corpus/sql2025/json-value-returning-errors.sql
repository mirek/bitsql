-- @step batch
DECLARE @j json=N'{"s":"abcdef","n":12.75,"b":true}'; SELECT JSON_VALUE(@j,'$.s' RETURNING varchar(3)) AS s,JSON_VALUE(@j,'$.n' RETURNING int) AS n,JSON_VALUE(@j,'$.b' RETURNING int) AS b;
-- @step batch
DECLARE @j json=N'{"s":"abc"}'; SELECT JSON_VALUE(@j,'strict $.s' RETURNING int) AS s;
-- @step batch
DECLARE @j json=N'{"n":2147483648}'; SELECT JSON_VALUE(@j,'strict $.n' RETURNING int) AS n;
-- @step batch
DECLARE @j json=N'{"s":"abcdef"}'; SELECT JSON_VALUE(@j,'strict $.s' RETURNING varchar(3)) AS s;
-- @step batch
DECLARE @j json=N'{"d":"2024-02-29","t":"12:34:56.123"}'; SELECT JSON_VALUE(@j,'$.d' RETURNING datetime) AS d,JSON_VALUE(@j,'$.t' RETURNING time(3)) AS t;
