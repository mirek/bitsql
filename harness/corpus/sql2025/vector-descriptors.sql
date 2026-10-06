-- Vector descriptor syntax, base type names and argument errors.
-- @step batch
DECLARE @v vector(3,float32)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,FLOAT32)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,[float32])='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float16)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float64)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,int)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,1)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,max)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,float32,1)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(float32)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,)='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,"float32")='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
-- @step batch
DECLARE @v vector(3,'float32')='[1,2,3]'; SELECT @v AS v, VECTORPROPERTY(@v,'BaseType') AS base_type;
