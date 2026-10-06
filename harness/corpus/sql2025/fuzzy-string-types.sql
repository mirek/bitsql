-- Fuzzy string family compatibility and NULL binding.
-- @step setup
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS char(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS char(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS char(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS varchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS char(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS char(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nvarchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS varchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS char(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS varchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS varchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS varchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS varchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nvarchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS char(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS varchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nvarchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nvarchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS char(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nvarchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS varchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nvarchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST('a' AS nvarchar(5)) COLLATE Latin1_General_100_CI_AS,CAST('b' AS nvarchar(5))) AS d;
-- @step batch
SELECT EDIT_DISTANCE(NULL,'a') AS d;
-- @step batch
SELECT EDIT_DISTANCE(CAST(NULL AS int),'a') AS d;
-- @step batch
SELECT EDIT_DISTANCE('a',CAST(NULL AS int)) AS d;
-- @step batch
SELECT EDIT_DISTANCE(NULL,NULL) AS d;
-- @step batch
SELECT EDIT_DISTANCE(N'a','b') AS d;
-- @step batch
SELECT EDIT_DISTANCE('a',N'b') AS d;
