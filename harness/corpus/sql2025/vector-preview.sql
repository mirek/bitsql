-- Repeated batches must not reuse a preview-off binding after preview changes.
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT @v AS v;
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT @v AS v;
-- @step batch
CREATE TABLE vpreview(h vector(3,float16)); INSERT vpreview VALUES('[1,2,3]');
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = OFF;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT @v AS v;
-- @step batch
SELECT h,DATALENGTH(h) AS bytes FROM vpreview;
-- @step batch
SELECT VECTOR_NORM(h,'norm2') AS n FROM vpreview;
-- @step batch
SELECT CAST('[1,2,3]' AS vector(3,float16)) AS v;
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
SELECT CAST('[1,2,3]' AS vector(3,float16)) AS v;
