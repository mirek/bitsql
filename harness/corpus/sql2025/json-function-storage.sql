-- Native JSON function results and allocation state.
-- @step batch
DECLARE @j json=N'{"a":"abcdefgh","b":1}';
SELECT DATALENGTH(@j) AS original,DATALENGTH(JSON_MODIFY(@j,'$.a','x')) AS shrink,DATALENGTH(JSON_MODIFY(@j,'$.a','abcdefghijklmnop')) AS grow,DATALENGTH(JSON_MODIFY(@j,'$.b',NULL)) AS del,DATALENGTH(JSON_MODIFY(@j,'$.c',2)) AS added;
-- @step batch
DECLARE @j json=N'{"a":"abcdefgh","b":1}';
SET @j=JSON_MODIFY(@j,'$.a','x');
SELECT @j AS j,DATALENGTH(@j) AS bytes,DATALENGTH(JSON_QUERY(@j,'$')) AS root,DATALENGTH(CAST(CAST(@j AS nvarchar(max)) AS json)) AS rebuilt;
-- @step batch
DECLARE @j json=N'{"a":[1,2],"b":{"c":3}}';
SELECT DATALENGTH(@j) AS original,DATALENGTH(JSON_QUERY(@j,'$')) AS root,DATALENGTH(JSON_QUERY(@j,'$.a')) AS a,DATALENGTH(JSON_QUERY(@j,'$.b')) AS b;
-- @step batch
SELECT DATALENGTH(CAST(NULL AS json)) AS n,DATALENGTH(JSON_ARRAY(1,2 RETURNING JSON)) AS a,DATALENGTH(JSON_OBJECT('a':1 RETURNING JSON)) AS b;
-- @step batch
DECLARE @j json=N'{"a":1}'; SELECT DATALENGTH(JSON_ARRAY(@j)) AS a,DATALENGTH(JSON_OBJECT('b':@j)) AS b;
