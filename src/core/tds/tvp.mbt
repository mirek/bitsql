// Table-valued parameters in RPC requests (MS-TDS 2.2.5.5.5, TVP_TYPE
// 0xF3), as tedious writes TYPES.TVP (lib/data-types/tvp.js):
//
//   F3 DbName(B_VARCHAR) OwningSchema(B_VARCHAR) TypeName(B_VARCHAR)
//   ColumnCount(USHORT, 0xFFFF = NULL table)
//   { UserType(ULONG) Flags(USHORT) TYPE_INFO ColName(B_VARCHAR) } * count
//   [TVP_ORDER_UNIQUE 0x10 | TVP_COLUMN_ORDERING 0x11 ...] TVP_END 0x00
//   { TVP_ROW 0x01 value * columns-without-fDefault } * TVP_END 0x00

///|
/// TVP column flag fDefault: the column has no values in the rows.
pub const TVP_DEFAULT_COLUMN : Int = 0x200

///|
pub(all) struct TvpColumn {
  user_type : Int
  flags : Int
  type_info : TypeInfo
} derive(Debug)

///|
/// A decoded table-valued parameter. `rows` is None for a NULL table
/// (column count 0xFFFF); otherwise each row has one value per column
/// (Null for fDefault columns).
pub(all) struct Tvp {
  database : String
  schema : String
  name : String
  columns : Array[TvpColumn]
  rows : Array[Array[WireValue]]?
} derive(Debug)

///|
/// Reads a TVP after its 0xF3 type byte.
pub fn read_tvp(r : Reader) -> Tvp raise TdsError {
  let database = r.b_varchar()
  let schema = r.b_varchar()
  let name = r.b_varchar()
  let count = r.u16le()
  let columns : Array[TvpColumn] = []
  let null_table = count == 0xFFFF
  if !null_table {
    for _ in 0..<count {
      let user_type = r.u32le().to_int()
      let flags = r.u16le()
      let type_info = read_type_info(r)
      ignore(r.b_varchar()) // ColName: always empty
      columns.push({ user_type, flags, type_info, })
    }
  }
  // optional metadata tokens, then TVP_END
  while true {
    match r.u8() {
      0x00 => break
      0x10 => {
        // TVP_ORDER_UNIQUE: count, (ColNum USHORT, flags BYTE) * count
        let n = r.u16le()
        r.skip(n * 3)
      }
      0x11 => {
        // TVP_COLUMN_ORDERING: count, ColNum USHORT * count
        let n = r.u16le()
        r.skip(n * 2)
      }
      t =>
        raise Malformed(
          "unexpected TVP metadata token 0x\{t.to_string(radix=16)}",
        )
    }
  }
  let rows : Array[Array[WireValue]] = []
  while true {
    match r.u8() {
      0x00 => break
      0x01 => {
        let row = []
        for c in columns {
          if (c.flags & TVP_DEFAULT_COLUMN) != 0 {
            row.push(WireValue::Null)
          } else {
            row.push(read_value(r, c.type_info))
          }
        }
        rows.push(row)
      }
      t =>
        raise Malformed("unexpected TVP row token 0x\{t.to_string(radix=16)}")
    }
  }
  {
    database,
    schema,
    name,
    columns,
    rows: if null_table {
      None
    } else {
      Some(rows)
    },
  }
}
