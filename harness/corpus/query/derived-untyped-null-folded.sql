-- Known gap (not allowlisted): a constant CASE / COALESCE / IIF that folds
-- to a bare reference of a derived table's NULL constant column keeps the
-- column's flags (1) in SQL Server; bitsql binds that reference as the
-- untyped NULL literal and reports a computed column (33). Types, values
-- and errors agree.
-- @step batch
SELECT CASE WHEN 1 = 1 THEN s.o END AS a, COALESCE(s.o, s.o) AS b,
  COALESCE(NULL, s.o) AS c, IIF(1 = 1, s.o, NULL) AS d,
  CASE WHEN 1 = 1 THEN (s.o) END AS e
FROM (SELECT NULL AS o) s;
