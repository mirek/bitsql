-- JSON errors at run time: states depend on whether the document is a max
-- type (nvarchar(n) / literal: 13609 and 13608 state 1, 13623/13624 state
-- 2; nvarchar(max) / varchar(max): the other way round, 13624 for several
-- values 3 / 4), and every JSON error ends the batch (the second SELECT does
-- not run) unless a TRY catches it. A missing member stops validation at
-- the container it was looked up in, a step of the wrong kind at once.
-- @step batch
DECLARE @j nvarchar(max) = N'x'; SELECT JSON_VALUE(@j, '$.a') a; SELECT 2 b
-- @step batch
DECLARE @j nvarchar(100) = N'x'; SELECT JSON_VALUE(@j, '$.a') a; SELECT 2 b
-- @step batch
DECLARE @j varchar(max) = '{"a":1}'; SELECT JSON_VALUE(@j, 'strict $.b') a
-- @step batch
DECLARE @j nvarchar(100) = N'{"a":1}'; SELECT JSON_VALUE(@j, 'strict $.b') a
-- @step batch
DECLARE @j nvarchar(max) = N'{"a":{}}'; SELECT JSON_VALUE(@j, 'strict $.a') a
-- @step batch
DECLARE @j nvarchar(100) = N'{"a":{}}'; SELECT JSON_VALUE(@j, 'strict $.a') a
-- @step batch
DECLARE @j nvarchar(max) = N'{"a":1}'; SELECT JSON_QUERY(@j, 'strict $.a') a
-- @step batch
DECLARE @j nvarchar(100) = N'{"a":1}'; SELECT JSON_QUERY(@j, 'strict $.a') a
-- @step batch
DECLARE @j nvarchar(max) = N'[1,2]'; SELECT JSON_QUERY(@j, 'strict $[*]') a
-- @step batch
DECLARE @j nvarchar(100) = N'[1,2]'; SELECT JSON_QUERY(@j, 'strict $[*]') a
-- @step batch
DECLARE @j nvarchar(max) = N'1'; SELECT JSON_VALUE(@j, '$') a
-- @step batch
SELECT JSON_VALUE(CAST(N'x' AS nvarchar(max)), '$.a') a
-- @step batch
SELECT JSON_VALUE(UPPER(N'x'), '$.a') a
-- @step batch
DECLARE @p nvarchar(max) = N'$[0to0]'; SELECT JSON_VALUE(N'[1]', @p) a; SELECT 2 b
-- @step batch
DECLARE @p nvarchar(max) = N'$[2 to 1]'; SELECT JSON_VALUE(N'[1]', @p) a
-- @step batch
DECLARE @p nvarchar(max) = NULL; SELECT JSON_VALUE(N'{}', @p) a; SELECT 2 b
-- @step batch
DECLARE @k nvarchar(max) = NULL; SELECT JSON_OBJECT(@k:1) a; SELECT 2 b
-- @step batch
DECLARE @j nvarchar(max) = N'{"a":1}'; SELECT JSON_MODIFY(@j, 'append strict $.a', 1) a; SELECT 2 b
-- @step batch
DECLARE @j nvarchar(max) = N'x'; SELECT * FROM OPENJSON(@j); SELECT 2 b
-- @step batch
DECLARE @j nvarchar(max) = N'x'; BEGIN TRY SELECT JSON_VALUE(@j, '$.a') a; END TRY BEGIN CATCH SELECT ERROR_NUMBER() n, ERROR_STATE() s END CATCH; SELECT 2 b
-- @step batch
DECLARE @j nvarchar(max) = N'{"a":"' + REPLICATE(CAST(N'x' AS nvarchar(max)), 5000) + N'"}'; SELECT JSON_VALUE(@j, 'strict $.a') a
-- @step batch
SELECT JSON_VALUE(N'{"a":{"b":1},"c":x}', N'$.a.missing') a, JSON_VALUE(N'[1,2', N'$.x') b, JSON_VALUE(N'{"a":[1],"b":x}', N'$.a[5]') c, JSON_VALUE(N'{"a":[1],"b":x}', N'$.a.x') d, JSON_VALUE(N'{"a":{"x":1},"b":x}', N'$.a[0]') e, JSON_QUERY(N'[null]', N'strict $[0]') f
-- @step batch
SELECT JSON_VALUE(N'{"a":1} x', N'$.missing') a
-- @step rpc
-- @param @j nvarchar(max) = "x"
SELECT JSON_VALUE(@j, '$.a') AS a
-- @step rpc
-- @param @j nvarchar(max) = "{\"a\":1}"
SELECT JSON_VALUE(@j, 'strict $.b') AS a
