-- Vector common-type selection, typed NULL and mixed expressions.
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CASE WHEN 1=1 THEN @v ELSE '[4,5,6]' END AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CASE WHEN 1=0 THEN @v ELSE '[4,5,6]' END AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT COALESCE(@v,'[4,5,6]') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT COALESCE(CAST(NULL AS vector(3)),'[4,5,6]') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT ISNULL(CAST(NULL AS vector(3)),'[4,5,6]') AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CASE WHEN 1=1 THEN @v ELSE CAST('[4,5,6]' AS json) END AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CASE WHEN 1=1 THEN @v ELSE CAST('[4,5,6]' AS vector(3)) END AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CASE WHEN 1=1 THEN @v ELSE CAST('[4,5]' AS vector(2)) END AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT CASE WHEN 1=1 THEN @v ELSE 1 END AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT @v+'[4,5,6]' AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT @v||'[4,5,6]' AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT IIF(@v='[1,2,3]',1,0) AS v;
-- @step batch
DECLARE @v vector(3)='[1,2,3]'; SELECT NULLIF(@v,@v) AS v;
-- @step batch
SELECT CAST('[1,2,3]' AS vector(3)) AS v UNION ALL SELECT '[4,5,6]';
