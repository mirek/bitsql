-- sys.objects / sys.tables / views / procedures / triggers / sql_modules
-- rows after DDL with named constraints and modules.
-- @step setup
CREATE TABLE dbo.parent (id int NOT NULL CONSTRAINT pk_parent PRIMARY KEY, code varchar(10) NOT NULL CONSTRAINT uq_parent_code UNIQUE, note nvarchar(max) NULL);
CREATE TABLE dbo.child (id int IDENTITY(1,1) NOT NULL CONSTRAINT pk_child PRIMARY KEY NONCLUSTERED, pid int NOT NULL CONSTRAINT fk_child_parent REFERENCES dbo.parent (id) ON DELETE CASCADE, qty decimal(9,2) NOT NULL CONSTRAINT df_child_qty DEFAULT 0 CONSTRAINT ck_child_qty CHECK (qty >= 0), total AS qty * 2);
-- @step setup
CREATE VIEW dbo.v_child AS SELECT id, pid FROM dbo.child
-- @step setup
CREATE PROCEDURE dbo.p_child AS SELECT 1 AS one
-- @step setup
CREATE FUNCTION dbo.f_child (@x int) RETURNS int AS BEGIN RETURN @x END
-- @step setup
CREATE TRIGGER dbo.tr_child ON dbo.child AFTER INSERT AS SET NOCOUNT ON
-- @step batch
SELECT name, type, type_desc, OBJECT_NAME(parent_object_id) AS parent, schema_id, principal_id, is_ms_shipped, is_published, is_schema_published FROM sys.objects WHERE is_ms_shipped = 0 ORDER BY name;
SELECT name, type, max_column_id_used, lob_data_space_id, uses_ansi_nulls, lock_escalation_desc, durability_desc, temporal_type_desc, ledger_type_desc, is_memory_optimized, text_in_row_limit FROM sys.tables ORDER BY name;
SELECT name, type, with_check_option, is_date_correlation_view, ledger_view_type, ledger_view_type_desc, has_snapshot, is_dropped_ledger_view FROM sys.views;
SELECT name, type, type_desc, is_auto_executed, is_execution_replicated, is_repl_serializable_only, skips_repl_constraints FROM sys.procedures;
SELECT name, OBJECT_NAME(parent_id) AS parent, parent_class, parent_class_desc, type, type_desc, is_disabled, is_instead_of_trigger, is_ms_shipped, is_not_for_replication FROM sys.triggers;
SELECT OBJECT_NAME(object_id) AS name, definition, uses_ansi_nulls, uses_quoted_identifier, is_schema_bound, uses_database_collation, is_recompiled, null_on_null_input, execute_as_principal_id, uses_native_compilation, inline_type, is_inlineable FROM sys.sql_modules ORDER BY 1;
SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE, DATA_TYPE, NUMERIC_PRECISION, ROUTINE_BODY, ROUTINE_DEFINITION, IS_DETERMINISTIC, SQL_DATA_ACCESS, IS_NULL_CALL, SCHEMA_LEVEL_ROUTINE, MAX_DYNAMIC_RESULT_SETS FROM INFORMATION_SCHEMA.ROUTINES ORDER BY ROUTINE_NAME;
SELECT TABLE_NAME, VIEW_DEFINITION, CHECK_OPTION, IS_UPDATABLE FROM INFORMATION_SCHEMA.VIEWS;
SELECT TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'v_child' ORDER BY ORDINAL_POSITION;
SELECT OBJECTPROPERTY(OBJECT_ID('dbo.child'), 'IsUserTable') AS u, OBJECTPROPERTY(OBJECT_ID('dbo.v_child'), 'IsView') AS v, OBJECTPROPERTY(OBJECT_ID('dbo.p_child'), 'IsProcedure') AS p, OBJECTPROPERTY(OBJECT_ID('dbo.f_child'), 'IsScalarFunction') AS f, OBJECTPROPERTY(OBJECT_ID('dbo.tr_child'), 'IsTrigger') AS tr, OBJECTPROPERTY(OBJECT_ID('dbo.pk_child'), 'IsPrimaryKey') AS pk, OBJECTPROPERTY(OBJECT_ID('dbo.child'), 'TableHasIdentity') AS hi, OBJECTPROPERTY(OBJECT_ID('dbo.child'), 'TableHasClustIndex') AS hc, OBJECTPROPERTY(OBJECT_ID('dbo.parent'), 'TableHasForeignRef') AS fr;
SELECT OBJECT_ID('dbo.v_child', 'V') - OBJECT_ID('dbo.v_child') AS same, OBJECT_ID('dbo.v_child', 'U') AS wrong_type, OBJECT_SCHEMA_NAME(OBJECT_ID('dbo.child')) AS sch, OBJECT_NAME(OBJECT_ID('[dbo].[child]')) AS nm, OBJECT_DEFINITION(OBJECT_ID('dbo.ck_child_qty')) AS def;
