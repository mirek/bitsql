-- @step batch
CREATE TABLE t(id int CONSTRAINT pk PRIMARY KEY,j json);
INSERT t VALUES(1,N'{"a":[1,2]}');
CREATE JSON INDEX ix ON t(j);
-- @step batch
SELECT id FROM t WHERE JSON_PATH_EXISTS(j,'$.missing[last]')=1;
-- @step batch
SELECT id FROM t WHERE JSON_PATH_EXISTS(j,'$.a[last]')=1;
-- @step batch
SELECT id FROM t WHERE JSON_PATH_EXISTS(j,'$.a[0,1]')=1;

-- @step batch
SELECT id FROM t WHERE JSON_CONTAINS(j,2,'$.missing',2)=1;
-- @step batch
SELECT id FROM t WHERE JSON_CONTAINS(j,2,'bad')=1;
-- @step batch
DROP INDEX ix ON t;
-- @step batch
SELECT id FROM t WHERE JSON_PATH_EXISTS(j,'$.a[last]')=1;
