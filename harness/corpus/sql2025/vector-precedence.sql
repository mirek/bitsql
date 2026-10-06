-- Vector mixed-type precedence, both directions and runtime branches.
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('x' AS char(1)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST('x' AS char(1)) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('x' AS nchar(1)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST('x' AS nchar(1)) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST(0x01 AS binary(1)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST(0x01 AS binary(1)) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST(0x01 AS varbinary(1)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST(0x01 AS varbinary(1)) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('<a/>' AS xml) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST('<a/>' AS xml) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST(1 AS sql_variant) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST(1 AS sql_variant) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('[4,5]' AS vector(2)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST('[4,5]' AS vector(2)) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST(NULL AS vector(3)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(3)='[1,2,3]'; SELECT CASE WHEN @flag=1 THEN CAST(NULL AS vector(3)) ELSE @v END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(1)='[1]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('[1]' AS varchar(max)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(2)='[1,1]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('[1]' AS varchar(max)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(4)='[1,1,1,1]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('[1]' AS varchar(max)) END AS v;
-- @step batch
DECLARE @flag int=1,@v vector(10)='[1,1,1,1,1,1,1,1,1,1]'; SELECT CASE WHEN @flag=1 THEN @v ELSE CAST('[1]' AS varchar(max)) END AS v;
