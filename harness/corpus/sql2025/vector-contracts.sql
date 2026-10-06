-- Vector type and operation contracts.
-- @step batch
DECLARE @v vector; SELECT @v AS v;
-- @step batch
DECLARE @v vector(0); SELECT @v AS v;
-- @step batch
DECLARE @v vector(1); SELECT @v AS v;
-- @step batch
DECLARE @v vector(1998); SELECT @v AS v;
-- @step batch
DECLARE @v vector(1999); SELECT @v AS v;
-- @step batch
DECLARE @v vector(max); SELECT @v AS v;
-- @step batch
DECLARE @v vector(3,float32); SELECT @v AS v;
-- @step batch
DECLARE @v vector(3,float16); SELECT @v AS v;
-- @step batch
DECLARE @v vector(3,float64); SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1,2]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1,2,3,4]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1,null,3]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1,true,3]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1,"2",3]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'{"a":1}'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1,2,3] garbage'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1e39,0,0]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1e-50,-0,1.23456789]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1,2,3,]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'null'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = N'[1e309,2,3]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(3) = '[-3,4,0]'; SELECT VECTOR_NORM(@v,'norm1') AS n, VECTOR_NORMALIZE(@v,'norm1') AS v;
-- @step batch
DECLARE @v vector(3) = '[-3,4,0]'; SELECT VECTOR_NORM(@v,'norm2') AS n, VECTOR_NORMALIZE(@v,'norm2') AS v;
-- @step batch
DECLARE @v vector(3) = '[-3,4,0]'; SELECT VECTOR_NORM(@v,'norminf') AS n, VECTOR_NORMALIZE(@v,'norminf') AS v;
-- @step batch
DECLARE @v vector(3) = '[-3,4,0]'; SELECT VECTOR_NORM(@v,'norm0') AS n, VECTOR_NORMALIZE(@v,'norm0') AS v;
-- @step batch
DECLARE @v vector(3) = '[-3,4,0]'; SELECT VECTOR_NORM(@v,'Norm2') AS n, VECTOR_NORMALIZE(@v,'Norm2') AS v;
-- @step batch
DECLARE @v vector(3) = '[-3,4,0]'; SELECT VECTOR_NORM(@v,' norm2') AS n, VECTOR_NORMALIZE(@v,' norm2') AS v;
-- @step batch
DECLARE @v vector(3) = '[-3,4,0]'; SELECT VECTOR_NORM(@v,'bad') AS n, VECTOR_NORMALIZE(@v,'bad') AS v;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]', @w vector(3) = '[2,4,6]'; SELECT VECTOR_DISTANCE('cosine', @v,@w) AS d;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]', @w vector(3) = '[2,4,6]'; SELECT VECTOR_DISTANCE('dot', @v,@w) AS d;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]', @w vector(3) = '[2,4,6]'; SELECT VECTOR_DISTANCE('euclidean', @v,@w) AS d;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]', @w vector(3) = '[2,4,6]'; SELECT VECTOR_DISTANCE('Cosine', @v,@w) AS d;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]', @w vector(3) = '[2,4,6]'; SELECT VECTOR_DISTANCE('manhattan', @v,@w) AS d;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]', @w vector(3) = '[2,4,6]'; SELECT VECTOR_DISTANCE('bad', @v,@w) AS d;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v,'Dimensions') AS p, SQL_VARIANT_PROPERTY(VECTORPROPERTY(@v,'Dimensions'),'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v,'BaseType') AS p, SQL_VARIANT_PROPERTY(VECTORPROPERTY(@v,'BaseType'),'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v,'dimensions') AS p, SQL_VARIANT_PROPERTY(VECTORPROPERTY(@v,'dimensions'),'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v,'basetype') AS p, SQL_VARIANT_PROPERTY(VECTORPROPERTY(@v,'basetype'),'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v,'Precision') AS p, SQL_VARIANT_PROPERTY(VECTORPROPERTY(@v,'Precision'),'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v,'MaxLength') AS p, SQL_VARIANT_PROPERTY(VECTORPROPERTY(@v,'MaxLength'),'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3) = '[1,2,3]'; SELECT VECTORPROPERTY(@v,'bad') AS p, SQL_VARIANT_PROPERTY(VECTORPROPERTY(@v,'bad'),'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3); SELECT VECTOR_NORM(@v,'norm2') AS n, VECTOR_NORMALIZE(@v,'norm2') AS v, VECTOR_DISTANCE('bad',@v,@v) AS d, VECTORPROPERTY(@v,'BaseType') AS p;
-- @step batch
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- @step batch
DECLARE @v vector(3,float16) = '[1,2,3]'; SELECT @v AS v,DATALENGTH(@v) AS n,VECTORPROPERTY(@v,'BaseType') AS ty;
-- @step batch
DECLARE @v vector(3996,float16); SELECT @v AS v;
-- @step batch
DECLARE @v vector(3997,float16); SELECT @v AS v;
