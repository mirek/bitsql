-- Trap: @@ROWCOUNT is reset by SET, PRINT, BEGIN TRAN, COMMIT and more.
SELECT x FROM (VALUES (1), (2), (3)) v(x);
SELECT @@ROWCOUNT AS after_select;
SELECT x FROM (VALUES (1), (2), (3)) v(x);
SET ANSI_NULLS ON;
SELECT @@ROWCOUNT AS after_set;
SELECT x FROM (VALUES (1), (2), (3)) v(x);
PRINT 'p';
SELECT @@ROWCOUNT AS after_print;
SELECT x FROM (VALUES (1), (2), (3)) v(x);
BEGIN TRANSACTION;
SELECT @@ROWCOUNT AS after_begin_tran;
SELECT x FROM (VALUES (1), (2), (3)) v(x);
COMMIT;
SELECT @@ROWCOUNT AS after_commit;
DECLARE @v int = 5;
SELECT @@ROWCOUNT AS after_declare_init;
SELECT x FROM (VALUES (1), (2)) v(x);
IF 1 = 1 SELECT @@ROWCOUNT AS inside_if;
