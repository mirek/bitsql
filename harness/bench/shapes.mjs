// Query and DML shapes shared by bench.mjs (emulator scaling) and
// compare.mjs (emulator vs real SQL Server). setupSql(n) creates the tables
// every shape reads (w, w2 with n rows; wc, wcc empty FK children).
export const queries = [
  ['GROUP BY p (997 groups)', 'SELECT p, COUNT(*) FROM w GROUP BY p'],
  ['GROUP BY v (5003 groups)', 'SELECT v, COUNT(*) FROM w GROUP BY v'],
  ['SELECT DISTINCT v', 'SELECT DISTINCT v FROM w'],
  ['COUNT(DISTINCT v)', 'SELECT COUNT(DISTINCT v) FROM w'],
  ['UNION', 'SELECT v FROM w UNION SELECT v FROM w'],
  ['EXCEPT', 'SELECT v FROM w EXCEPT SELECT v FROM w WHERE id % 2 = 0'],
  ['INTERSECT', 'SELECT p FROM w INTERSECT SELECT w_id FROM w2'],
  ['IN (uncorrelated subquery)', 'SELECT COUNT(*) FROM w WHERE id IN (SELECT w_id FROM w2)'],
  ['NOT IN (uncorrelated subquery)', 'SELECT COUNT(*) FROM w WHERE p NOT IN (SELECT p FROM w WHERE id < 100)'],
  ['EXISTS (correlated, unindexed)', 'SELECT COUNT(*) FROM w WHERE EXISTS (SELECT 1 FROM w2 WHERE w2.w_id = w.id)'],
  ['scalar subquery (correlated)', 'SELECT COUNT(*) FROM w WHERE (SELECT COUNT(*) FROM w2 WHERE w2.w_id = w.p) > 0'],
  ['scalar subquery (uncorrelated)', 'SELECT COUNT(*) FROM w WHERE p = (SELECT MAX(p) FROM w2 JOIN w ON w.id = w2.id)'],
  ['equi-join', 'SELECT COUNT(*) FROM w JOIN w2 ON w2.w_id = w.id'],
  ['ORDER BY v', 'SELECT TOP 10 id FROM w ORDER BY v, id'],
  ['ORDER BY v after a shared non-ASCII prefix', "SELECT TOP 10 id FROM w ORDER BY N'é' + v, id"],
  ['ORDER BY accented text', 'SELECT TOP 10 id FROM w ORDER BY NCHAR(224 + id % 30) + v, id'],
  ['ROW_NUMBER over v', 'SELECT COUNT(*) FROM (SELECT ROW_NUMBER() OVER (PARTITION BY v ORDER BY id) AS r FROM w) x WHERE r = 1'],
  // DML, rolled back
  ['DELETE WHERE IN (subquery)', 'BEGIN TRAN; DELETE w WHERE id IN (SELECT w_id FROM w2); ROLLBACK'],
  ['UPDATE FROM join', 'BEGIN TRAN; UPDATE w SET p = w2.w_id FROM w JOIN w2 ON w2.id = w.id; ROLLBACK'],
  ['UPDATE all rows', 'BEGIN TRAN; UPDATE w SET p = p + 1; ROLLBACK'],
  ['INSERT with FOREIGN KEY', 'BEGIN TRAN; INSERT wc SELECT id, id FROM w; ROLLBACK'],
  ['DELETE parent rows (FK checked)', 'BEGIN TRAN; INSERT wc SELECT id, id FROM w WHERE id % 2 = 0; DELETE w WHERE id % 2 = 1; ROLLBACK'],
  ['DELETE with ON DELETE CASCADE', 'BEGIN TRAN; INSERT wcc SELECT id, id FROM w; DELETE w; ROLLBACK'],
  ['MERGE', 'BEGIN TRAN; MERGE w2 AS t USING w AS s ON t.id = s.id WHEN MATCHED THEN UPDATE SET w_id = s.p WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.p); ROLLBACK'],
]

export const setupSql = n => `
  DROP TABLE IF EXISTS wc; DROP TABLE IF EXISTS wcc; DROP TABLE IF EXISTS w; DROP TABLE IF EXISTS w2;
  CREATE TABLE w (id int PRIMARY KEY, p int, v nvarchar(20));
  INSERT w SELECT g.value, g.value % 997, CONCAT(N'v', g.value % 5003) FROM GENERATE_SERIES(1, ${n}) g;
  CREATE TABLE w2 (id int PRIMARY KEY, w_id int);
  INSERT w2 SELECT g.value, g.value * 3 FROM GENERATE_SERIES(1, ${n}) g;
  CREATE TABLE wc (id int PRIMARY KEY, w_id int REFERENCES w (id));
  CREATE TABLE wcc (id int PRIMARY KEY, w_id int REFERENCES w (id) ON DELETE CASCADE);`
