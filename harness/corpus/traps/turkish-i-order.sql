-- Pre-existing unsupported Turkish collation (BitSQL error 448), outside compact-key scope.
-- @step batch
SELECT id FROM (VALUES (1, N'İ'), (2, N'ı')) v(id, word) ORDER BY word COLLATE Turkish_CI_AS, id;
