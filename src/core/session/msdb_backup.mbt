// msdb backup history tables (backupset, backupmediaset, backupmediafamily,
// backupfile, restorehistory, restorefile) as read-only virtual tables over
// the server's BackupStore (session/backup.mbt). Column names, types,
// nullability and identity are msdb's (captured: msdb.sys.columns on SQL
// Server 17.0.5005, corpus backup/msdb-history). They bind as scope-2
// sources like the catalog views, under `MSDB_VIEW_OFFSET`.

///|
const MSDB_VIEW_OFFSET : Int = 2097152

///|
/// (column, type, nullable, identity) of each msdb table.
priv struct MsdbTable {
  name : String
  columns : Array[(String, @types.SqlType, Bool, Bool)]
}

///|
fn mcol(
  name : String,
  ty : @types.SqlType,
  nullable : Bool,
) -> (String, @types.SqlType, Bool, Bool) {
  (name, ty, nullable, false)
}

///|
fn msdb_nvc(n : Int) -> @types.SqlType {
  NVarChar(Some(n), @types.default_collation)
}

///|
fn msdb_char(n : Int) -> @types.SqlType {
  Char(n, @types.default_collation)
}

///|
let msdb_tables : Array[MsdbTable] = [
  {
    name: "backupset",
    columns: [
      ("backup_set_id", Int, false, true),
      mcol("backup_set_uuid", UniqueIdentifier, false),
      mcol("media_set_id", Int, false),
      mcol("first_family_number", TinyInt, true),
      mcol("first_media_number", SmallInt, true),
      mcol("last_family_number", TinyInt, true),
      mcol("last_media_number", SmallInt, true),
      mcol("catalog_family_number", TinyInt, true),
      mcol("catalog_media_number", SmallInt, true),
      mcol("position", Int, true),
      mcol("expiration_date", DateTime, true),
      mcol("software_vendor_id", Int, true),
      mcol("name", msdb_nvc(128), true),
      mcol("description", msdb_nvc(255), true),
      mcol("user_name", msdb_nvc(128), true),
      mcol("software_major_version", TinyInt, true),
      mcol("software_minor_version", TinyInt, true),
      mcol("software_build_version", SmallInt, true),
      mcol("time_zone", SmallInt, true),
      mcol("mtf_minor_version", TinyInt, true),
      mcol("first_lsn", Numeric(25, 0), true),
      mcol("last_lsn", Numeric(25, 0), true),
      mcol("checkpoint_lsn", Numeric(25, 0), true),
      mcol("database_backup_lsn", Numeric(25, 0), true),
      mcol("database_creation_date", DateTime, true),
      mcol("backup_start_date", DateTime, true),
      mcol("backup_finish_date", DateTime, true),
      mcol("type", msdb_char(1), true),
      mcol("sort_order", SmallInt, true),
      mcol("code_page", SmallInt, true),
      mcol("compatibility_level", TinyInt, true),
      mcol("database_version", Int, true),
      mcol("backup_size", Numeric(20, 0), true),
      mcol("database_name", msdb_nvc(128), true),
      mcol("server_name", msdb_nvc(128), true),
      mcol("machine_name", msdb_nvc(128), true),
      mcol("flags", Int, true),
      mcol("unicode_locale", Int, true),
      mcol("unicode_compare_style", Int, true),
      mcol("collation_name", msdb_nvc(128), true),
      mcol("is_password_protected", Bit, true),
      mcol("recovery_model", msdb_nvc(60), true),
      mcol("has_bulk_logged_data", Bit, true),
      mcol("is_snapshot", Bit, true),
      mcol("is_readonly", Bit, true),
      mcol("is_single_user", Bit, true),
      mcol("has_backup_checksums", Bit, true),
      mcol("is_damaged", Bit, true),
      mcol("begins_log_chain", Bit, true),
      mcol("has_incomplete_metadata", Bit, true),
      mcol("is_force_offline", Bit, true),
      mcol("is_copy_only", Bit, true),
      mcol("first_recovery_fork_guid", UniqueIdentifier, true),
      mcol("last_recovery_fork_guid", UniqueIdentifier, true),
      mcol("fork_point_lsn", Numeric(25, 0), true),
      mcol("database_guid", UniqueIdentifier, true),
      mcol("family_guid", UniqueIdentifier, true),
      mcol("differential_base_lsn", Numeric(25, 0), true),
      mcol("differential_base_guid", UniqueIdentifier, true),
      mcol("compressed_backup_size", Numeric(20, 0), true),
      mcol("key_algorithm", msdb_nvc(32), true),
      mcol("encryptor_thumbprint", VarBinary(Some(20)), true),
      mcol("encryptor_type", msdb_nvc(32), true),
      mcol("last_valid_restore_time", DateTime, true),
      mcol("compression_algorithm", msdb_nvc(32), true),
    ],
  },
  {
    name: "backupmediaset",
    columns: [
      ("media_set_id", Int, false, true),
      mcol("media_uuid", UniqueIdentifier, true),
      mcol("media_family_count", TinyInt, true),
      mcol("name", msdb_nvc(128), true),
      mcol("description", msdb_nvc(255), true),
      mcol("software_name", msdb_nvc(128), true),
      mcol("software_vendor_id", Int, true),
      mcol("MTF_major_version", TinyInt, true),
      mcol("mirror_count", TinyInt, true),
      mcol("is_password_protected", Bit, true),
      mcol("is_compressed", Bit, true),
      mcol("is_encrypted", Bit, true),
    ],
  },
  {
    name: "backupmediafamily",
    columns: [
      mcol("media_set_id", Int, false),
      mcol("family_sequence_number", TinyInt, false),
      mcol("media_family_id", UniqueIdentifier, true),
      mcol("media_count", Int, true),
      mcol("logical_device_name", msdb_nvc(128), true),
      mcol("physical_device_name", msdb_nvc(260), true),
      mcol("device_type", TinyInt, true),
      mcol("physical_block_size", Int, true),
      mcol("mirror", TinyInt, false),
    ],
  },
  {
    name: "backupfile",
    columns: [
      mcol("backup_set_id", Int, false),
      mcol("first_family_number", TinyInt, true),
      mcol("first_media_number", SmallInt, true),
      mcol("filegroup_name", msdb_nvc(128), true),
      mcol("page_size", Int, true),
      mcol("file_number", Numeric(10, 0), false),
      mcol("backed_up_page_count", Numeric(10, 0), true),
      mcol("file_type", msdb_char(1), true),
      mcol("source_file_block_size", Numeric(10, 0), true),
      mcol("file_size", Numeric(20, 0), true),
      mcol("logical_name", msdb_nvc(128), true),
      mcol("physical_drive", msdb_nvc(260), true),
      mcol("physical_name", msdb_nvc(260), true),
      mcol("state", TinyInt, true),
      mcol("state_desc", msdb_nvc(64), true),
      mcol("create_lsn", Numeric(25, 0), true),
      mcol("drop_lsn", Numeric(25, 0), true),
      mcol("file_guid", UniqueIdentifier, true),
      mcol("read_only_lsn", Numeric(25, 0), true),
      mcol("read_write_lsn", Numeric(25, 0), true),
      mcol("differential_base_lsn", Numeric(25, 0), true),
      mcol("differential_base_guid", UniqueIdentifier, true),
      mcol("backup_size", Numeric(20, 0), true),
      mcol("filegroup_guid", UniqueIdentifier, true),
      mcol("is_readonly", Bit, true),
      mcol("is_present", Bit, true),
    ],
  },
  {
    name: "restorehistory",
    columns: [
      ("restore_history_id", Int, false, true),
      mcol("restore_date", DateTime, true),
      mcol("destination_database_name", msdb_nvc(128), true),
      mcol("user_name", msdb_nvc(128), true),
      mcol("backup_set_id", Int, false),
      mcol("restore_type", msdb_char(1), true),
      mcol("replace", Bit, true),
      mcol("recovery", Bit, true),
      mcol("restart", Bit, true),
      mcol("stop_at", DateTime, true),
      mcol("device_count", TinyInt, true),
      mcol("stop_at_mark_name", msdb_nvc(128), true),
      mcol("stop_before", Bit, true),
    ],
  },
  {
    name: "restorefile",
    columns: [
      mcol("restore_history_id", Int, false),
      mcol("file_number", Numeric(10, 0), true),
      mcol("destination_phys_drive", msdb_nvc(260), true),
      mcol("destination_phys_name", msdb_nvc(260), true),
    ],
  },
]

///|
/// Binds `msdb.dbo.<table>` / `msdb..<table>` (or `dbo.<table>` while
/// msdb is the current database) for the backup history tables.
fn Session::msdb_binding(
  self : Session,
  name : @ast.ObjectName,
) -> @bind.TableBinding? {
  let n = name.parts.length()
  let in_msdb = if n >= 3 {
    name.parts[n - 3].name.to_lower() == "msdb"
  } else {
    self.rt.database.to_lower() == "msdb"
  }
  guard in_msdb && n <= 3 else { return None }
  if n >= 2 && !(name.parts[n - 2].name.to_lower() is ("" | "dbo")) {
    return None
  }
  let base = name.parts[n - 1].name.to_lower()
  for k, t in msdb_tables {
    if t.name == base {
      return Some({
        scope: 2,
        id: MSDB_VIEW_OFFSET + k,
        schema: "dbo",
        name: t.name,
        columns: t.columns.map(c => @bind.ColumnRef::{
          qualifier: t.name,
          name: c.0,
          ty: c.1,
          nullable: c.2,
          origin: BaseColumn(identity=c.3),
        }),
      })
    }
  }
  None
}

///|
/// Rows of msdb table `k` (index into `msdb_tables`).
fn Session::msdb_rows(
  self : Session,
  k : Int,
) -> Array[(Int64, Array[@types.Value])] {
  let store = self.server.backups
  let (major, minor, build) = self.rt.build
  let rows : Array[Array[@types.Value]] = []
  match msdb_tables.get(k).map(t => t.name) {
    Some("backupset") =>
      for set in store.history {
        let size = dec0(backup_size(set))
        rows.push([
          Int(set.backup_set_id),
          Guid(set.set_guid),
          Int(set.media_set_id),
          TinyInt(1),
          SmallInt(1),
          TinyInt(1),
          SmallInt(1),
          TinyInt(1),
          SmallInt(1),
          Int(set.position),
          Null,
          Int(4608),
          str_or_null(set.name),
          str_or_null(set.description),
          String(set.user),
          TinyInt(major),
          TinyInt(minor),
          SmallInt(build),
          SmallInt(0),
          TinyInt(0),
          dec0(set.first_lsn),
          dec0(set.first_lsn + 2400000L),
          dec0(set.first_lsn),
          dec0(0L),
          dt(set.start),
          dt(set.start),
          dt(set.start),
          String("D"),
          SmallInt(52),
          SmallInt(0),
          TinyInt(set.options.compat_level),
          Int(998),
          size,
          String(set.database),
          String(self.rt.server_name),
          String(self.rt.server_name),
          Int(backup_flags(set)),
          Int(1033),
          Int(196609),
          String(set.options.collation.name),
          Bit(false),
          String(set.options.recovery),
          Bit(false),
          Bit(false),
          Bit(false),
          Bit(false),
          Bit(set.checksum),
          Bit(false),
          Bit(false),
          Bit(false),
          Bit(false),
          Bit(set.copy_only),
          Guid(set.family),
          Guid(set.family),
          Null,
          Guid(set.family),
          Guid(set.family),
          Null,
          Null,
          size,
          Null,
          Null,
          Null,
          Null,
          if set.compressed {
            String("MS_XPRESS")
          } else {
            Null
          },
        ])
      }
    Some("backupmediaset") =>
      for m in store.media_history {
        rows.push([
          Int(m.media_set_id),
          Guid(m.media_guid),
          TinyInt(1),
          Null,
          Null,
          String("Microsoft SQL Server"),
          Int(4608),
          TinyInt(1),
          TinyInt(1),
          Bit(false),
          Bit(m.compressed),
          Null,
        ])
      }
    Some("backupmediafamily") =>
      for m in store.media_history {
        rows.push([
          Int(m.media_set_id),
          TinyInt(1),
          Guid(m.family_guid),
          Int(1),
          Null,
          String(m.path),
          TinyInt(2),
          Int(4096),
          TinyInt(0),
        ])
      }
    Some("backupfile") =>
      for set in store.history {
        for j, f in set.files {
          let data = j == 0
          let pages = if data { BACKUP_DATA_PAGES } else { BACKUP_LOG_PAGES }
          rows.push([
            Int(set.backup_set_id),
            TinyInt(1),
            SmallInt(1),
            if data {
              String("PRIMARY")
            } else {
              Null
            },
            if data {
              Int(8192)
            } else {
              Null
            },
            dec0((j + 1).to_int64()),
            dec0(pages.to_int64()),
            String(if data { "D" } else { "L" }),
            dec0(4096L),
            dec0(8388608L),
            String(f.0),
            String("C:\\"),
            String(f.1),
            TinyInt(0),
            String("ONLINE"),
            dec0(0L),
            Null,
            name_guid(set.database, j + 1),
            Null,
            Null,
            Null,
            Null,
            dec0(pages.to_int64() * 8192L),
            if data {
              Guid(set.family)
            } else {
              Null
            },
            Bit(false),
            Bit(true),
          ])
        }
      }
    Some("restorehistory") =>
      for r in store.restores {
        rows.push([
          Int(r.id),
          dt(r.date),
          String(r.database),
          String(r.user),
          Int(r.backup_set_id),
          String("D"),
          Bit(r.replace),
          Bit(true),
          Bit(false),
          Null,
          TinyInt(1),
          Null,
          Null,
        ])
      }
    Some("restorefile") =>
      for r in store.restores {
        for j, p in r.files {
          rows.push([
            Int(r.id),
            dec0((j + 1).to_int64()),
            String("C:\\"),
            String(p),
          ])
        }
      }
    _ => ()
  }
  rows.mapi((j, r) => (j.to_int64(), r))
}
