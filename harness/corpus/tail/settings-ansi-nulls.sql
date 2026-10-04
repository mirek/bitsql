-- SET ANSI_NULLS OFF: = and <> against a NULL literal (also parenthesized)
-- or a bare variable/parameter are two-valued (NULL = NULL is true);
-- column = column, expressions and ordering operators stay three-valued.
-- IN lists and simple CASE compare per item. Modules keep their
-- CREATE-time setting (SET inside a procedure has no effect; dynamic SQL
-- inherits; SESSIONPROPERTY and @@OPTIONS show the module's value);
-- sys.sql_modules, sys.tables and OBJECTPROPERTY report it.
-- @step setup
CREATE TABLE dbo.t(id int, a int NULL, b int NULL, s varchar(10) NULL);
INSERT dbo.t VALUES (1, NULL, NULL, NULL), (2, 1, NULL, 'x'), (3, 1, 1, 'y'), (4, 2, 1, NULL);
-- @step batch
SET ANSI_NULLS OFF;
DECLARE @v int = NULL, @w int = NULL, @one int = 1;
SELECT CASE WHEN NULL = NULL THEN 1 ELSE 0 END, CASE WHEN 1 = NULL THEN 1 ELSE 0 END, CASE WHEN 1 <> NULL THEN 1 ELSE 0 END,
  CASE WHEN NULL <> NULL THEN 1 ELSE 0 END, CASE WHEN @v = @w THEN 1 ELSE 0 END, CASE WHEN @v <> @w THEN 1 ELSE 0 END,
  CASE WHEN @v = NULL THEN 1 ELSE 0 END, CASE WHEN @one <> @v THEN 1 ELSE 0 END, CASE WHEN NOT (@one = @v) THEN 1 ELSE 0 END,
  CASE WHEN @v != NULL THEN 1 ELSE 0 END, CASE WHEN @v > NULL THEN 1 ELSE 0 END, CASE WHEN @v >= NULL THEN 1 ELSE 0 END;
SET ANSI_NULLS ON
-- @step batch
SET ANSI_NULLS OFF;
DECLARE @v int = NULL;
SELECT id FROM dbo.t WHERE a = NULL;
SELECT id FROM dbo.t WHERE a <> NULL;
SELECT id FROM dbo.t WHERE a = @v;
SELECT id FROM dbo.t WHERE NOT (a = @v);
SELECT id FROM dbo.t WHERE a = b;
SELECT id FROM dbo.t WHERE a <> b;
SELECT id FROM dbo.t WHERE NOT (a = b);
SELECT id FROM dbo.t WHERE a IN (NULL);
SELECT id FROM dbo.t WHERE a NOT IN (2, NULL);
SELECT id FROM dbo.t WHERE a IN (@v, 2);
SELECT id FROM dbo.t WHERE a = CAST(NULL AS int);
SELECT id FROM dbo.t WHERE a = (NULL);
SELECT id FROM dbo.t WHERE a + 1 = NULL;
SELECT id FROM dbo.t WHERE NULL = a;
SELECT id FROM dbo.t WHERE s = NULL;
SELECT id FROM dbo.t WHERE a = @v + 1;
SELECT id FROM dbo.t WHERE a = ISNULL(@v, NULL);
SELECT id, CASE a WHEN NULL THEN 'null' ELSE 'x' END FROM dbo.t;
SELECT id FROM dbo.t WHERE a > NULL;
SELECT id FROM dbo.t x WHERE EXISTS (SELECT 1 FROM dbo.t y WHERE y.a = x.b AND y.id = x.id);
SELECT x.id FROM dbo.t x JOIN dbo.t y ON x.a = y.b WHERE x.id = y.id;
SELECT id FROM dbo.t WHERE NULLIF(a, NULL) = NULL;
SELECT id FROM dbo.t WHERE a BETWEEN NULL AND 5;
SELECT id FROM dbo.t WHERE id IN (SELECT id FROM dbo.t WHERE a = NULL);
IF @v = NULL PRINT 'if-null';
SELECT id FROM dbo.t WHERE a = ALL (SELECT NULL);
SELECT id FROM dbo.t WHERE a IN (SELECT b FROM dbo.t);
SELECT id FROM dbo.t WHERE a NOT IN (SELECT b FROM dbo.t);
SELECT id FROM dbo.t WHERE a = ANY (SELECT b FROM dbo.t WHERE id > 2);
SELECT id FROM dbo.t WHERE a <> ALL (SELECT b FROM dbo.t WHERE id < 3);
SELECT id FROM dbo.t WHERE a <> ANY (SELECT b FROM dbo.t WHERE id IN (1, 3));
SELECT id FROM dbo.t WHERE a = ALL (SELECT b FROM dbo.t WHERE id IN (1, 2));
SELECT id FROM dbo.t WHERE a = ALL (SELECT b FROM dbo.t WHERE id = 99);
SELECT id FROM dbo.t WHERE a <> ANY (SELECT b FROM dbo.t WHERE id = 99);
SET ANSI_NULLS ON
-- @step rpc
-- @param @p int = null
SET ANSI_NULLS OFF; SELECT id FROM dbo.t WHERE a = @p; SET ANSI_NULLS ON; SELECT id FROM dbo.t WHERE a = @p
-- @step setup
SET ANSI_NULLS OFF
-- @step setup
CREATE PROCEDURE dbo.p_off AS SELECT id FROM dbo.t WHERE a = NULL; SELECT SESSIONPROPERTY('ANSI_NULLS') AS sp, @@OPTIONS & 32 AS opt; EXEC('SELECT id FROM dbo.t WHERE a = NULL'); SET ANSI_NULLS ON; SELECT id FROM dbo.t WHERE a = NULL
-- @step setup
CREATE VIEW dbo.v_off AS SELECT id FROM dbo.t WHERE a = NULL
-- @step setup
CREATE FUNCTION dbo.f_off(@x int) RETURNS int AS BEGIN RETURN CASE WHEN @x = NULL THEN 1 ELSE 0 END END
-- @step setup
CREATE FUNCTION dbo.tf_off() RETURNS TABLE AS RETURN SELECT id FROM dbo.t WHERE a = NULL
-- @step setup
CREATE TRIGGER dbo.tr_off ON dbo.t AFTER UPDATE AS SELECT id FROM inserted WHERE a = NULL
-- @step setup
SET ANSI_NULLS ON
-- @step setup
CREATE PROCEDURE dbo.p_on AS SELECT id FROM dbo.t WHERE a = NULL; SET ANSI_NULLS OFF; SELECT id FROM dbo.t WHERE a = NULL; SELECT SESSIONPROPERTY('ANSI_NULLS') AS sp
-- @step setup
CREATE VIEW dbo.v_on AS SELECT id FROM dbo.t WHERE a = NULL
-- @step batch
EXEC dbo.p_off
-- @step batch
SELECT SESSIONPROPERTY('ANSI_NULLS'); EXEC dbo.p_on; SELECT SESSIONPROPERTY('ANSI_NULLS'), @@OPTIONS & 32
-- @step batch
SELECT * FROM dbo.v_off; SELECT * FROM dbo.tf_off(); SELECT dbo.f_off(NULL)
-- @step batch
UPDATE dbo.t SET b = b WHERE id IN (1, 2)
-- @step batch
SET ANSI_NULLS OFF; SELECT * FROM dbo.v_on; EXEC dbo.p_on; SET ANSI_NULLS ON
-- @step batch
SELECT o.name, m.uses_ansi_nulls, OBJECTPROPERTY(o.object_id, 'ExecIsAnsiNullsOn') AS e, OBJECTPROPERTY(o.object_id, 'IsAnsiNullsOn') AS i FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id ORDER BY o.name
-- @step batch
SELECT OBJECTPROPERTY(OBJECT_ID('dbo.t'), 'IsAnsiNullsOn'), OBJECTPROPERTY(OBJECT_ID('dbo.t'), 'ExecIsAnsiNullsOn'), uses_ansi_nulls FROM sys.tables WHERE name = 't'
-- @step batch
SET ANSI_NULLS OFF; EXEC sp_executesql N'SELECT id FROM dbo.t WHERE a = NULL; SET ANSI_NULLS ON; SELECT id FROM dbo.t WHERE a = NULL'; SELECT id FROM dbo.t WHERE a = NULL; SET ANSI_NULLS ON
-- @step batch
SET ANSI_NULLS OFF; CREATE TABLE dbo.t2(a int); SET ANSI_NULLS ON; SELECT OBJECTPROPERTY(OBJECT_ID('dbo.t2'), 'IsAnsiNullsOn'), uses_ansi_nulls FROM sys.tables WHERE name = 't2'
-- @step batch
SET ANSI_NULLS OFF; SELECT id FROM dbo.t WHERE a = NULL; SET ANSI_NULLS ON; SELECT id FROM dbo.t WHERE a = NULL
-- @step batch
SET ANSI_NULLS OFF; SELECT SESSIONPROPERTY('ANSI_NULLS'), @@OPTIONS & 32; SET ANSI_NULLS ON; SELECT SESSIONPROPERTY('ANSI_NULLS'), @@OPTIONS & 32
