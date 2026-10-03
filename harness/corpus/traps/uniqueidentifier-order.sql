-- Trap: uniqueidentifier sorts by the last 6 bytes first (byte groups compared right to left).
-- @step setup
CREATE TABLE g (label varchar(10) NOT NULL, id uniqueidentifier NOT NULL);
INSERT INTO g VALUES
  ('a', '00000000-0000-0000-0000-000000000001'),
  ('b', '01000000-0000-0000-0000-000000000000'),
  ('c', '00000000-0100-0000-0000-000000000000'),
  ('d', '00000000-0000-0100-0000-000000000000'),
  ('e', '00000000-0000-0000-0100-000000000000'),
  ('f', '00000000-0000-0000-0001-000000000000'),
  ('g', '00000000-0000-0000-0000-010000000000'),
  ('h', 'FFFFFFFF-FFFF-FFFF-FFFF-000000000000');
-- @step batch
SELECT label, id FROM g ORDER BY id, label;
SELECT CAST(CAST('6F9619FF-8B86-D011-B42D-00C04FD430C8' AS uniqueidentifier) AS binary(16)) AS wire_bytes;
SELECT MIN(id) AS min_id, MAX(id) AS max_id FROM g;
