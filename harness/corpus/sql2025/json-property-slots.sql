-- Native JSON deletion, reinsertion and reuse of property slots.
-- @step batch
CREATE TABLE jo(id int PRIMARY KEY,j json);
INSERT jo VALUES(1,N'{"a":1}'),(2,N'{"a":1,"b":2}'),(3,N'{"a":1,"b":2,"c":3}');
-- @step batch
UPDATE jo SET j=JSON_MODIFY(j,'$.a',NULL);
SELECT id,j,DATALENGTH(j) AS bytes FROM jo ORDER BY id;
-- @step batch
UPDATE jo SET j=JSON_MODIFY(j,'$.z',9);
SELECT id,j,DATALENGTH(j) AS bytes FROM jo ORDER BY id;
-- @step batch
UPDATE jo SET j=JSON_MODIFY(j,'$.a',4);
SELECT id,j,DATALENGTH(j) AS bytes FROM jo ORDER BY id;
-- @step batch
UPDATE jo SET j=JSON_MODIFY(j,'$.b',NULL);
UPDATE jo SET j=JSON_MODIFY(j,'$.z',NULL);
SELECT id,j,DATALENGTH(j) AS bytes FROM jo ORDER BY id;
-- @step batch
UPDATE jo SET j=JSON_MODIFY(j,'$.b',8);
UPDATE jo SET j=JSON_MODIFY(j,'$.z',7);
SELECT id,j,DATALENGTH(j) AS bytes FROM jo ORDER BY id;
-- @step batch
DECLARE @j json=N'{"a":{"x":1,"y":2},"b":{"y":3,"x":4}}'; SELECT @j AS j,DATALENGTH(@j) AS bytes;
