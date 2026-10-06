-- Vector input JSON validation and error precedence.
-- @step batch
DECLARE @v vector(1)=N''; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N' '; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'1'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'true'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'false'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'"x"'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'{}'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[[]]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[[1]]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[{}]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[null,]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[1,]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[01]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[+1]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[.5]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[1.]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[1e]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[NaN]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[1]x'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[1, true, bad]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[1e1000]'; SELECT @v AS v;
-- @step batch
DECLARE @v vector(1)=N'[-1e-1000]'; SELECT @v AS v;
