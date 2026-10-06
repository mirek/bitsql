-- Preview float16 storage, rounding, norms and distance contracts.
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,-1.23456,65504]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(3,float16)='[1e-8,1e-7,-0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(3,float16)='[65519,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(3,float16)='[65520,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(3,float16)='[65536,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(3,float16)='[65504,65504,65504]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(3,float16)='[0,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORM(@v,'norminf') AS ni,VECTOR_NORMALIZE(@v,'norm2') AS unit;
-- @step batch
DECLARE @v vector(7,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(8,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(9,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(16,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(17,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(31,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(32,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(33,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(64,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(65,float16)='[-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666,-0.66666,-0.33333,0.0,0.33333,0.66666]'; SELECT @v AS v,VECTOR_NORM(@v,'norm1') AS n1,VECTOR_NORM(@v,'norm2') AS n2,VECTOR_NORMALIZE(@v,'norm2') AS unit,VECTOR_DISTANCE('dot',@v,@v) AS dot,VECTOR_DISTANCE('cosine',@v,@v) AS cosine;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,0.2,0.3]',@w vector(3,float32)='[0.1,0.2,0.3]'; SELECT CAST(@v AS vector(3,float32)) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,0.2,0.3]',@w vector(3,float32)='[0.1,0.2,0.3]'; SELECT CAST(@w AS vector(3,float16)) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,0.2,0.3]',@w vector(3,float32)='[0.1,0.2,0.3]'; SELECT VECTOR_DISTANCE('dot',@v,@w) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,0.2,0.3]',@w vector(3,float32)='[0.1,0.2,0.3]'; SELECT VECTOR_DISTANCE('dot',@w,@v) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,0.2,0.3]',@w vector(3,float32)='[0.1,0.2,0.3]'; SELECT COALESCE(@v,@w) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,0.2,0.3]',@w vector(3,float32)='[0.1,0.2,0.3]'; SELECT COALESCE(@w,@v) AS v;
-- @step batch
CREATE TABLE vh (id int,h vector(3,float16)); INSERT vh VALUES(1,'[0.1,0.2,0.3]'); SELECT id,h,DATALENGTH(h) AS bytes FROM vh; SELECT name,system_type_id,user_type_id,max_length,precision,scale FROM sys.columns WHERE object_id=OBJECT_ID('vh') ORDER BY column_id;
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = OFF;
-- @step batch
SELECT id,h,DATALENGTH(h) AS bytes FROM vh;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT @v AS v;
