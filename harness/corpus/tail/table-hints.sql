-- Table hints in FROM: batch-level compile errors 321 (hint as written),
-- 1047 (conflicting isolation / granularity / UPDLOCK-XLOCK classes; NOLOCK
-- with any granularity or lock mode), 10746, 367, 8171 (state 2 NOEXPAND,
-- 1 IGNORE_*), 307/308 missing index id/name, 8622 (state 1 FORCESEEK
-- without a leading-key predicate, state 2 INDEX(0) with another index);
-- the legacy `t (NOLOCK)` / `t a (NOLOCK)` form; 319 prints 'with'.
-- @step setup
CREATE TABLE hp (id int NOT NULL CONSTRAINT PK_hp PRIMARY KEY, v int); INSERT INTO hp VALUES (1,1),(2,2);
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, SERIALIZABLE)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, HOLDLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, UPDLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, XLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, TABLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, ROWLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, READCOMMITTED)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, READUNCOMMITTED)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, NOLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (ROWLOCK, PAGLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (ROWLOCK, TABLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (TABLOCK, TABLOCKX)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (PAGLOCK, TABLOCKX)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (UPDLOCK, XLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (UPDLOCK, TABLOCKX)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (SERIALIZABLE, REPEATABLEREAD)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (SERIALIZABLE, HOLDLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (READCOMMITTED, READCOMMITTEDLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (READCOMMITTED, REPEATABLEREAD)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (READPAST, REPEATABLEREAD)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (READPAST, READCOMMITTED)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (READPAST, UPDLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (READPAST, TABLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOWAIT, READPAST)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOWAIT, NOLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (FORCESEEK, FORCESCAN)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (FORCESEEK, INDEX(0))
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (INDEX(0), INDEX(1))
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (INDEX(PK_hp))
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (INDEX(IX_Missing))
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (INDEX(5))
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (INDEX(1, 0))
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOEXPAND)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (SNAPSHOT)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (FORCESEEK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (FORCESEEK(PK_hp(id)))
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (forcescan)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (SPATIAL_WINDOW_MAX_CELLS=8)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (KEEPIDENTITY)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (KEEPDEFAULTS)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (IGNORE_CONSTRAINTS)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (IGNORE_TRIGGERS)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (FASTFIRSTROW)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (Bogus)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (nolock nolock)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (TABLOCK, UPDLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (FORCESEEK) WHERE id = 1
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (FORCESEEK) WHERE v = 1
-- @step batch
SELECT COUNT(*) AS n FROM hp (NOLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp h (NOLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NOLOCK) AS h
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hp WITH (bogus)
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hp WITH (INDEX(IX_Missing))
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hp WITH (NOLOCK, SERIALIZABLE)
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hp WITH (noexpand)
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hp WITH (snapshot)
-- @step batch
SELECT 1 AS a; SELECT COUNT(*) AS n FROM hp WITH (forceseek)
-- @step batch
SELECT * FROM (SELECT 1 AS a) d WITH (NOLOCK)
-- @step batch
CREATE VIEW hv AS SELECT id FROM hp
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (NOLOCK)
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (NOEXPAND)
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (FORCESEEK)
-- @step batch
SELECT COUNT(*) AS n FROM hv WITH (bogus)
-- @step batch
SELECT COUNT(*) AS n FROM hp WITH (NoLock, Serializable)
