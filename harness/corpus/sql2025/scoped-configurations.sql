-- SQL Server 2025 scoped configuration defaults and variant base types.
-- @step batch
SELECT * FROM sys.database_scoped_configurations ORDER BY configuration_id;
-- @step batch
SELECT configuration_id, SQL_VARIANT_PROPERTY(value,'BaseType') AS value_type, SQL_VARIANT_PROPERTY(value_for_secondary,'BaseType') AS secondary_type, SQL_VARIANT_PROPERTY(value,'MaxLength') AS value_length, SQL_VARIANT_PROPERTY(value,'Collation') AS value_collation FROM sys.database_scoped_configurations ORDER BY configuration_id;
