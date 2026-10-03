-- Exhausted sequences raise 11728; CYCLE wraps to MINVALUE.
-- @step setup
CREATE SEQUENCE dbo.small AS tinyint START WITH 254 MAXVALUE 255;
CREATE SEQUENCE dbo.cyc AS int START WITH 2 MINVALUE 1 MAXVALUE 3 CYCLE;
-- @step batch
SELECT NEXT VALUE FOR dbo.small AS a;
SELECT NEXT VALUE FOR dbo.small AS b;
SELECT NEXT VALUE FOR dbo.small AS c;
SELECT 'continues' AS r;
-- @step batch
SELECT NEXT VALUE FOR dbo.cyc AS a;
SELECT NEXT VALUE FOR dbo.cyc AS b;
SELECT NEXT VALUE FOR dbo.cyc AS c;
