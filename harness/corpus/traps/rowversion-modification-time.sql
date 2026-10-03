-- Trap: rowversion is a database-wide counter assigned at modification time, not commit.
-- Values are expressed relative to @@DBTS so the case is independent of the fresh database's start value.
-- @step setup
CREATE TABLE rv (id int NOT NULL PRIMARY KEY, v int NOT NULL, ver rowversion);
INSERT INTO rv (id, v) VALUES (1, 10), (2, 20);
-- @step batch
DECLARE @before bigint = CAST(@@DBTS AS bigint);
BEGIN TRANSACTION;
UPDATE rv SET v = v + 1 WHERE id = 1;
SELECT CAST(ver AS bigint) - @before AS delta_in_tran, CAST(@@DBTS AS bigint) - @before AS dbts_delta,
       CAST(MIN_ACTIVE_ROWVERSION() AS bigint) - @before AS min_active_delta
FROM rv WHERE id = 1;
COMMIT;
SELECT CAST(MIN_ACTIVE_ROWVERSION() AS bigint) - CAST(@@DBTS AS bigint) AS min_active_after_commit;
SELECT id, CASE WHEN ver > (SELECT ver FROM rv WHERE id = 2) THEN 1 ELSE 0 END AS newer_than_2 FROM rv WHERE id = 1;
UPDATE rv SET v = v WHERE id = 2;
SELECT CAST(ver AS bigint) - @before AS delta_noop_update FROM rv WHERE id = 2;
