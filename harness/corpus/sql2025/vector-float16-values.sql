-- Preview float16 parsing and individual scalar operations.
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[0.1,-1.23456,65504]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[1e-8,1e-7,-0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[65519,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[65520,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[65536,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[65504,65504,65504]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[0,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[1.000488281249,1.000488281251,-1.000488281251]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[2.9802322387695312e-8,2.980232238769532e-8,5.960464477539063e-8]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[1e1000,0,0]'; SELECT @v AS v,DATALENGTH(@v) AS bytes,VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_NORM(@v,'norm2') AS v;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_NORMALIZE(@v,'norm2') AS v;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_DISTANCE('dot',@v,@v) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_DISTANCE('euclidean',@v,@v) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_DISTANCE('cosine',@v,@v) AS v;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTORPROPERTY(@v,'Dimensions') AS v;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_NORM(CAST(NULL AS vector(3,float16)),'norm2') AS v;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT VECTOR_NORMALIZE(CAST(NULL AS vector(3,float16)),'norm2') AS v;
