-- WAITFOR argument forms. String variables follow the literal time grammar
-- but a mismatch is 241 at run time (batch ends); varchar(max) is always
-- 241; int/smallint count seconds; NULL of any type completes at once;
-- other types are 9815 (statement-level, batch continues). Literals:
-- blanks between parts, ':fff' milliseconds, upper-case AM/PM after a blank.
-- @step batch
DECLARE @d VARCHAR(20) = '00:00:00:020'; WAITFOR DELAY @d; SELECT 'colon ms' AS r
-- @step batch
DECLARE @d VARCHAR(20) = '00:00:00.0005'; WAITFOR DELAY @d; SELECT 'not reached' AS r
-- @step batch
DECLARE @d VARCHAR(20) = '5'; WAITFOR DELAY @d
-- @step batch
DECLARE @d VARCHAR(20) = '00:00:00.100PM'; WAITFOR DELAY @d
-- @step batch
DECLARE @d VARCHAR(30) = '1900-01-01 00:00:00'; WAITFOR DELAY @d
-- @step batch
DECLARE @d VARCHAR(MAX) = ''; WAITFOR DELAY @d
-- @step batch
DECLARE @d VARCHAR(20) = '12:00:00.010 AM'; WAITFOR DELAY @d; SELECT 'am' AS r
-- @step batch
DECLARE @d NCHAR(12) = N'00:00:00.010'; WAITFOR DELAY @d; SELECT 'nchar' AS r
-- @step batch
DECLARE @d INT = 0; WAITFOR DELAY @d; SELECT @@ROWCOUNT AS rc
-- @step batch
DECLARE @d BIT = 1; WAITFOR DELAY @d; SELECT 'after 9815' AS r
-- @step batch
DECLARE @d INT; WAITFOR TIME @d; SELECT 'null int time' AS r
-- @step batch
WAITFOR DELAY '00:00:00 .01'; WAITFOR DELAY '00 :00:00'; WAITFOR DELAY ' '; WAITFOR DELAY '000:00:00.01'; SELECT 'blanks' AS r
-- @step batch
WAITFOR DELAY '0:0:0:5'; WAITFOR DELAY '00:00:00.01 AM '; SELECT 'ok' AS r
-- @step batch
WAITFOR DELAY '00:00:01 pm'
-- @step batch
WAITFOR DELAY '00:00:00.'
-- @step batch
WAITFOR DELAY '00:00:'
-- @step batch
WAITFOR DELAY '1:2:3:4:5'
-- @step batch
WAITFOR DELAY '00:00:00Z'
-- @step batch
WAITFOR DELAY '-1:00'
-- @step batch
EXEC sp_executesql N'WAITFOR DELAY ''abc'''
