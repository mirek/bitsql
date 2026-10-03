-- EXEC arguments: bare words are nvarchar strings; DEFAULT takes the
-- parameter's default (201 when it has none); arguments convert to the
-- parameter type (1.5 → 1), and a failure is 8114 state 5 at line 0 that
-- fails only the EXEC; 8144/8162 report line 0.
-- @step setup
CREATE PROCEDURE pv @v sql_variant AS SELECT SQL_VARIANT_PROPERTY(@v, 'BaseType') AS bt, SQL_VARIANT_PROPERTY(@v, 'MaxLength') AS ml, @v AS v
-- @step setup
CREATE PROCEDURE pd @a int, @b int = 7 AS SELECT @a AS a, @b AS b
-- @step setup
CREATE PROCEDURE p_in @a int AS SELECT @a AS a
-- @step setup
CREATE PROCEDURE p_ti @a tinyint AS SELECT @a AS a
-- @step setup
CREATE PROCEDURE p_out @a int, @b int = 5, @c int OUTPUT AS BEGIN SET @c = @a + @b; RETURN 3; END
-- @step batch
EXEC pv abc; EXEC pv [abc def]; EXEC pv dbo
-- @step batch
EXEC pd DEFAULT
-- @step batch
EXEC pd 1, DEFAULT; EXEC pd @a = 2, @b = DEFAULT
-- @step batch
EXEC p_in 'abc'; SELECT 'after' AS a
-- @step batch
DECLARE @s varchar(10) = 'abc'; EXEC p_in @s; SELECT 'after' AS a
-- @step batch
EXEC p_ti 300; SELECT 'after' AS a
-- @step batch
EXEC p_in 1.5; EXEC p_in '2'; EXEC p_in N'3'
-- @step batch
DECLARE @r int = 1; EXEC @r = pd 1, 2, 3; SELECT 'never' AS n
-- @step batch
DECLARE @o int; EXEC pd 1, @o OUTPUT
-- @step batch
DECLARE @r int, @x int; EXEC @r = p_out 1, DEFAULT, @x OUTPUT; SELECT @r AS r, @x AS x
