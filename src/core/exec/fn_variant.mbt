// Functions returning sql_variant that need no database access:
// SQL_VARIANT_PROPERTY (types/variant.mbt) and SERVERPROPERTY. Bound in
// bind/fn_variant.mbt; DATABASEPROPERTYEX, CONNECTIONPROPERTY and
// SESSIONPROPERTY are evaluated by the session (session/properties.mbt).

///|
fn call_variant(
  ctx : Ctx,
  name : String,
  v : Array[@types.Value],
) -> @types.Value? {
  match name {
    "SQL_VARIANT_PROPERTY" =>
      Some(
        match v[1] {
          String(p) => @types.sql_variant_property(v[0], p)
          _ => Null
        },
      )
    "SERVERPROPERTY" =>
      Some(
        match v[0] {
          String(p) => server_property(ctx.rt, p)
          _ => Null
        },
      )
    _ => None
  }
}

///|
/// Revision of the SQL Server release bitsql reports (the oracle image:
/// 17.0.5005.3, RTM-CU9, KB5122048).
let product_revision : Int = 3

///|
fn sv_string(s : String, len? : Int = 128) -> @types.Value {
  Variant(String(s), NVarChar(Some(len), @types.default_collation))
}

///|
fn sv_int(n : Int) -> @types.Value {
  Variant(Int(n), Int)
}

///|
/// SERVERPROPERTY(name): values captured from the oracle (SQL Server 2025
/// Developer edition container, corpus properties/serverproperty.sql).
/// Names are case-insensitive and not trimmed; unknown names are NULL.
/// Host-tied values (MachineName, ServerName, ComputerNamePhysicalNetBIOS)
/// come from the emulator's server name; ProcessID is a constant.
pub fn server_property(rt : Runtime, name : String) -> @types.Value {
  let (major, minor, build) = rt.build
  let minor2 = if minor < 10 { "0\{minor}" } else { minor.to_string() }
  match name.to_lower() {
    "buildclrversion" => sv_string("v4.0.30319")
    "collation" => sv_string(@types.default_collation.name)
    "collationid" => sv_int(872468488)
    "comparisonstyle" => sv_int(196609)
    "computernamephysicalnetbios" | "machinename" | "servername" =>
      sv_string(rt.server_name)
    "edition" => sv_string("Enterprise Developer Edition (64-bit)")
    "editionid" => sv_int(-2117995310)
    "engineedition" => sv_int(3)
    "errorlogfilename" => sv_string("/var/opt/mssql/log/errorlog", len=260)
    "filestreamconfiguredlevel" | "filestreameffectivelevel" => sv_int(0)
    "filestreamsharename" => sv_string("MSSQLSERVER")
    "hadrmanagerstatus" => sv_int(1)
    "instancedefaultbackuppath" => sv_string("/var/opt/mssql/data")
    "instancedefaultdatapath" | "instancedefaultlogpath" =>
      sv_string("/var/opt/mssql/data/")
    "isadvancedanalyticsinstalled" | "isxtpsupported" => sv_int(1)
    "isbigdatacluster"
    | "isclustered"
    | "isexternalauthenticationonly"
    | "isexternalgovernanceenabled"
    | "isfulltextinstalled"
    | "ishadrenabled"
    | "isintegratedsecurityonly"
    | "islocaldb"
    | "ispolybaseinstalled"
    | "isserversuspendedforsnapshotbackup"
    | "issingleuser"
    | "istempdbmetadatamemoryoptimized"
    | "suspendeddatabasecount" => sv_int(0)
    "lcid" => sv_int(1033)
    "licensetype" => sv_string("DISABLED")
    "pathseparator" => sv_string("/")
    "processid" => sv_int(1)
    "productbuild" => sv_string(build.to_string())
    "productlevel" => sv_string("RTM")
    "productmajorversion" => sv_string(major.to_string())
    "productminorversion" => sv_string(minor.to_string())
    "productupdatelevel" => sv_string("CU9")
    "productupdatereference" => sv_string("KB5122048")
    "productversion" =>
      sv_string("\{major}.\{minor}.\{build}.\{product_revision}")
    // 2026-08-27 10:25:16.140: days since 1900-01-01, 1/300 s since midnight
    "resourcelastupdatedatetime" => Variant(DateTime(46259, 11254842), DateTime)
    "resourceversion" => sv_string("\{major}.\{minor2}.\{build}")
    "sqlcharset" => Variant(TinyInt(1), TinyInt)
    "sqlcharsetname" => sv_string("iso_1")
    "sqlsortorder" => Variant(TinyInt(52), TinyInt)
    "sqlsortordername" => sv_string("nocase_iso")
    _ => Null
  }
}
