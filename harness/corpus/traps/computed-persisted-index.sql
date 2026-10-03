-- Trap: persisted vs non-persisted computed columns differ in indexability.
-- @step setup
CREATE TABLE cc (a int NOT NULL, c_plain AS a * 2, c_float AS CAST(a AS float) * 2, c_float_p AS CAST(a AS float) * 2 PERSISTED);
INSERT INTO cc (a) VALUES (1), (2);
-- @step batch
SELECT a, c_plain, c_float, c_float_p FROM cc ORDER BY a;
SELECT name, is_persisted FROM sys.computed_columns WHERE object_id = OBJECT_ID('cc') ORDER BY name;
-- @step batch
CREATE INDEX ix_plain ON cc (c_plain);
-- @step batch
CREATE INDEX ix_float_p ON cc (c_float_p);
-- @step batch
CREATE INDEX ix_float ON cc (c_float);
