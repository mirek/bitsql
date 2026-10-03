-- SERVERPROPERTY: values, base types and lengths (sql_variant results).
-- Host-tied properties (MachineName, ServerName,
-- ComputerNamePhysicalNetBIOS, ProcessID) differ between servers: only
-- their types are compared.
-- @step batch
SELECT p, SERVERPROPERTY(p) AS v, SQL_VARIANT_PROPERTY(SERVERPROPERTY(p), 'BaseType') AS bt,
       SQL_VARIANT_PROPERTY(SERVERPROPERTY(p), 'MaxLength') AS ml
FROM (VALUES ('BuildClrVersion'), ('Collation'), ('CollationID'), ('ComparisonStyle'), ('Edition'), ('EditionID'),
  ('EngineEdition'), ('ErrorLogFileName'), ('FilestreamConfiguredLevel'), ('FilestreamEffectiveLevel'), ('FilestreamShareName'),
  ('HadrManagerStatus'), ('InstanceDefaultBackupPath'), ('InstanceDefaultDataPath'), ('InstanceDefaultLogPath'), ('InstanceName'),
  ('IsAdvancedAnalyticsInstalled'), ('IsBigDataCluster'), ('IsClustered'), ('IsExternalAuthenticationOnly'),
  ('IsExternalGovernanceEnabled'), ('IsFullTextInstalled'), ('IsHadrEnabled'), ('IsIntegratedSecurityOnly'), ('IsLocalDB'),
  ('IsPolyBaseInstalled'), ('IsServerSuspendedForSnapshotBackup'), ('IsSingleUser'), ('IsTempDbMetadataMemoryOptimized'),
  ('IsXTPSupported'), ('LCID'), ('LicenseType'), ('NumLicenses'), ('PathSeparator'), ('ProductBuild'), ('ProductBuildType'),
  ('ProductLevel'), ('ProductMajorVersion'), ('ProductMinorVersion'), ('ProductUpdateLevel'), ('ProductUpdateReference'),
  ('ProductUpdateType'), ('ProductVersion'), ('ResourceLastUpdateDateTime'), ('ResourceVersion'), ('SqlCharSet'),
  ('SqlCharSetName'), ('SqlSortOrder'), ('SqlSortOrderName'), ('SuspendedDatabaseCount'), ('Bogus'), ('productversion'),
  ('  Edition')) AS x(p);
SELECT p, SQL_VARIANT_PROPERTY(SERVERPROPERTY(p), 'BaseType') AS bt, SQL_VARIANT_PROPERTY(SERVERPROPERTY(p), 'MaxLength') AS ml,
       CASE WHEN SERVERPROPERTY(p) IS NULL THEN 0 ELSE 1 END AS present
FROM (VALUES ('MachineName'), ('ServerName'), ('ComputerNamePhysicalNetBIOS'), ('ProcessID')) AS x(p);
SELECT CASE WHEN CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) = @@SERVERNAME THEN 1 ELSE 0 END AS servername_matches,
       CASE WHEN SERVERPROPERTY('MachineName') = SERVERPROPERTY('ServerName') THEN 1 ELSE 0 END AS machine_is_server;
SELECT SERVERPROPERTY(NULL) AS a, SERVERPROPERTY(N'Edition') AS b, SERVERPROPERTY(1) AS c,
       CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
       CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')) AS product_version;
-- @step batch
SELECT SERVERPROPERTY();
