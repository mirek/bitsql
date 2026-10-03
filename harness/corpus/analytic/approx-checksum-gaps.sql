-- APPROX_COUNT_DISTINCT / CHECKSUM_AGG cases that need features bitsql lacks
-- (ntext, CHECKSUM of strings); kept separate so they stay visible.
-- @step setup
CREATE TABLE e (id int NOT NULL PRIMARY KEY, dept varchar(10) NOT NULL, sal int NULL, s nvarchar(10) NULL, b bigint NULL, f float NULL);
INSERT INTO e VALUES (1,'a',100,N'x',1,1.5),(2,'a',200,N'y',2,2.5),(3,'a',NULL,NULL,NULL,NULL),(4,'b',50,N'z',4,1.5),(5,'b',70,N'W',5,7),(6,'b',70,N'w',6,7),(7,'c',NULL,NULL,NULL,NULL);
-- @step batch
SELECT APPROX_COUNT_DISTINCT(CAST(s AS ntext)) FROM e;
-- @step batch
SELECT CHECKSUM_AGG(CHECKSUM(s)) FROM e;
