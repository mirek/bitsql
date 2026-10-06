-- Native json modification versus reserialization and binary storage size.
-- @step batch
CREATE TABLE js(id int PRIMARY KEY,j json);
INSERT js VALUES(1,'{"a":"abcdefgh","b":1}');
-- @step batch
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(CAST(CAST(j AS nvarchar(max)) AS json)) AS rebuilt FROM js;
-- @step batch
UPDATE js SET j.modify('$.a','x') WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(CAST(CAST(j AS nvarchar(max)) AS json)) AS rebuilt FROM js;
-- @step batch
UPDATE js SET j.modify('$.a','abcdefghijklmnop') WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(CAST(CAST(j AS nvarchar(max)) AS json)) AS rebuilt FROM js;
-- @step batch
UPDATE js SET j.modify('$.b',CAST(2147483647 AS bigint)) WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(CAST(CAST(j AS nvarchar(max)) AS json)) AS rebuilt FROM js;
-- @step batch
UPDATE js SET j.modify('$.b',1) WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(CAST(CAST(j AS nvarchar(max)) AS json)) AS rebuilt FROM js;
-- @step batch
UPDATE js SET j.modify('$.c',2) WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(CAST(CAST(j AS nvarchar(max)) AS json)) AS rebuilt FROM js;
-- @step batch
UPDATE js SET j.modify('$.a',NULL) WHERE id=1;
SELECT j,DATALENGTH(j) AS bytes,DATALENGTH(CAST(CAST(j AS nvarchar(max)) AS json)) AS rebuilt FROM js;
-- @step batch
DECLARE @j json='{"a":"abcdefgh"}'; SET @j.modify('$.a','x'); SELECT @j AS j,DATALENGTH(@j) AS bytes;
-- @step batch
DECLARE @j json='{"a":1,"a":{"unused":2}}'; SELECT @j AS j,DATALENGTH(@j) AS bytes;
