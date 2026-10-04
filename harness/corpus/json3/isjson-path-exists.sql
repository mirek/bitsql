-- ISJSON's type argument (a bare word: VALUE, ARRAY, OBJECT, SCALAR, any
-- case; 155 for another word, 1023 for anything else), the lazy nesting
-- limit (a container opened inside 129 containers fails at once, a scalar
-- or member name there only once it is complete), and JSON_PATH_EXISTS.
-- @step batch
SELECT ISJSON(N'1', SCALAR) a, ISJSON(N'true', SCALAR) b, ISJSON(N'null', VALUE) c, ISJSON(N'null', SCALAR) d, ISJSON(N'"x"', OBJECT) e, ISJSON(N'[]', ARRAY) f, ISJSON(N' 1 ', VALUE) g, ISJSON(N'', VALUE) h, ISJSON(N'1', value) i, ISJSON(N'1', [VALUE]) j, ISJSON(NULL, OBJECT) k
-- @step batch
SELECT ISJSON(N'1', 'VALUE') a
-- @step batch
SELECT ISJSON(N'1', NUMBER) a
-- @step batch
SELECT ISJSON(N'1', NULL) a
-- @step batch
DECLARE @t int = 1; SELECT ISJSON(N'1', @t) a
-- @step batch
DECLARE @j nvarchar(max) = REPLICATE(CAST(N'[' AS nvarchar(max)), 130); SELECT ISJSON(@j) a; SELECT 2 b
-- @step batch
DECLARE @j nvarchar(max) = REPLICATE(CAST(N'[' AS nvarchar(max)), 129) + N'"a'; SELECT ISJSON(@j) a
-- @step batch
DECLARE @j nvarchar(max) = REPLICATE(CAST(N'[' AS nvarchar(max)), 129) + N'1,'; SELECT ISJSON(@j) a
-- @step batch
DECLARE @j nvarchar(max) = REPLICATE(CAST(N'[' AS nvarchar(max)), 128) + N'{"a"'; SELECT ISJSON(@j) a
-- @step batch
DECLARE @j nvarchar(max) = REPLICATE(CAST(N'[' AS nvarchar(max)), 129) + N'1'; SELECT JSON_VALUE(@j, '$.x') a, JSON_VALUE(@j + N'x', '$.x') b
-- @step batch
DECLARE @j nvarchar(max) = N'[' + REPLICATE(CAST(N'[' AS nvarchar(max)), 129) + N'1'; SELECT JSON_VALUE(@j, '$[1]') a
-- @step batch
SELECT JSON_PATH_EXISTS(N'{"a":1}', N'$.a') a, JSON_PATH_EXISTS(N'{"a":1}', N'$.b') b, JSON_PATH_EXISTS(N'{"a":null}', N'$.a') c, JSON_PATH_EXISTS(N'x', N'$.a') d, JSON_PATH_EXISTS(N'{"a":1}', N'strict $.b') e, JSON_PATH_EXISTS(N'{"a":1,"b":x}', N'$.a') f, JSON_PATH_EXISTS(N'1', N'$') g, JSON_PATH_EXISTS(N'[1]', N'$') h, JSON_PATH_EXISTS(NULL, N'$') i, JSON_PATH_EXISTS(N'{"a":1} x', N'$.a') j
-- @step batch
SELECT JSON_PATH_EXISTS(N'{"a":1}', N'bad') a
-- @step batch
SELECT JSON_PATH_EXISTS(N'{}', NULL) a
-- @step batch
SELECT JSON_PATH_EXISTS(1, N'$') a
-- @step batch
SELECT JSON_PATH_EXISTS(N'{}', 1) a
-- @step batch
SELECT JSON_PATH_EXISTS(N'[1]', N'$[last]') a
-- @step batch
SELECT JSON_PATH_EXISTS(REPLICATE(CAST(N'[' AS nvarchar(max)), 200), '$[0]') a
