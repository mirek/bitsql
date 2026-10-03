-- Normalized definition text: AND/OR nesting on either side, BETWEEN and
-- IN inside AND/OR, unary minus and bitwise NOT placement, nested
-- arithmetic, datepart names and IIF.
-- @step setup
CREATE TABLE t (a int NULL, b int NULL, c int NULL, d datetime NULL,
  CONSTRAINT f01 CHECK (a > 0 AND (b > 0 AND c > 0)),
  CONSTRAINT f02 CHECK ((a > 0 AND b > 0) AND c > 0),
  CONSTRAINT f03 CHECK (a > 0 AND b BETWEEN 1 AND 2),
  CONSTRAINT f04 CHECK (a IN (1, 2) OR b > 0),
  CONSTRAINT f05 CHECK ((a > 0 OR b > 0) OR c > 0),
  CONSTRAINT f06 CHECK (-a + b > 0),
  CONSTRAINT f07 CHECK (a - -b > 0),
  CONSTRAINT f08 CHECK (~a & b = 0),
  CONSTRAINT f09 CHECK (a * (b * c) > 0),
  CONSTRAINT f10 CHECK (a % (b + c) >= 0),
  CONSTRAINT f11 CHECK (datepart(yyyy, d) > 2000 AND datediff(mi, d, d) = 0 AND month(d) > 0),
  CONSTRAINT f12 CHECK (iif(a > 0, b, c) IS NOT NULL OR a IS NULL),
  CONSTRAINT f13 CHECK (a = 007 AND b <> -0),
  CONSTRAINT f14 CHECK (NOT a > 1 OR NOT (b > 1 OR c > 1)),
  CONSTRAINT f15 CHECK (a + (b - c) * 2 > 0));
-- @step batch
SELECT name, definition FROM sys.check_constraints ORDER BY name;
