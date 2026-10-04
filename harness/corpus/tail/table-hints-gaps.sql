-- Table hint shapes bitsql does not emulate yet: READPAST with NOLOCK or
-- SERIALIZABLE is 650 after COLMETADATA, several legacy hints without WITH
-- are 207s + 215, a legacy INDEX() is 1018, table variables take no hints
-- (319), INDEX hints on a view are INFO 4430.
-- @step setup
CREATE TABLE hp (id int NOT NULL CONSTRAINT PK_hp PRIMARY KEY, v int); INSERT INTO hp VALUES (1,1),(2,2);
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, READPAST)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (READPAST, SERIALIZABLE)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK READPAST)
-- @step batch
SELECT COUNT(*) AS n FROM hp (NOLOCK, READPAST)
-- @step batch
SELECT COUNT(*) AS n FROM hp (BOGUS)
-- @step batch
SELECT COUNT(*) AS n FROM hp (INDEX(0))
-- @step batch
DECLARE @t TABLE(a int); SELECT * FROM @t WITH (NOLOCK)
-- @step batch
DECLARE @t TABLE(a int); SELECT * FROM @t WITH (bogus)
-- @step batch
CREATE VIEW hv AS SELECT id FROM hp
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (INDEX(1))
