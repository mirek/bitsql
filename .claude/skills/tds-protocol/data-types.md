# TDS Data Types

> Source: [MS-TDS] v20260223, Sections 2.2.5.1-2.2.5.7

## 13. Data Types

### TYPE_INFO Rule

```
TYPE_INFO = FIXEDLENTYPE
          / VARLENTYPE TYPE_VARLEN [COLLATION]                ; char/nchar/varchar/nvarchar/text/ntext
          / VARLENTYPE TYPE_VARLEN [PRECISION SCALE]          ; decimal/numeric
          / VARLENTYPE SCALE                                   ; TIME/DATETIME2/DATETIMEOFFSET
          / VARLENTYPE                                         ; DATE only (no extra fields)
          / PARTLENTYPE [USHORTMAXLEN] [COLLATION] [XML_INFO] [UDT_INFO]
          / NULLTYPE                                           ; 0x1F (RPCRequest only)
```

### Zero-Length Data Types

| ID | Name | Description |
|----|------|-------------|
| 0x1F | NULLTYPE | Null (only valid in RPCRequest, SQL Server never emits it) |

### Fixed-Length Data Types (FIXEDLENTYPE)

No TYPE_VARLEN in TYPE_INFO. Fixed byte count in TYPE_VARBYTE. NOT nullable (use INTNTYPE etc. for nullable).

| ID | Name | Size | SQL Type |
|----|------|------|----------|
| 0x30 | INT1TYPE | 1 byte | tinyint |
| 0x32 | BITTYPE | 1 byte | bit |
| 0x34 | INT2TYPE | 2 bytes | smallint |
| 0x38 | INT4TYPE | 4 bytes | int |
| 0x3A | DATETIM4TYPE | 4 bytes | smalldatetime |
| 0x3B | FLT4TYPE | 4 bytes | real |
| 0x3C | MONEYTYPE | 8 bytes | money |
| 0x3D | DATETIMETYPE | 8 bytes | datetime |
| 0x3E | FLT8TYPE | 8 bytes | float |
| 0x7A | MONEY4TYPE | 4 bytes | smallmoney |
| 0x7F | INT8TYPE | 8 bytes | bigint |

### Variable-Length Data Types (VARLENTYPE) — BYTELEN

TYPE_VARLEN = 1 byte length. NULL = `0x00`.

| ID | Name | Valid Lengths | SQL Type |
|----|------|--------------|----------|
| 0x24 | GUIDTYPE | 0x00 (null), 0x10 | uniqueidentifier |
| 0x26 | INTNTYPE | 0x01, 0x02, 0x04, 0x08 | tinyint/smallint/int/bigint |
| 0x68 | BITNTYPE | 0x00 (null), 0x01 | bit |
| 0x6A | DECIMALNTYPE | 0x05, 0x09, 0x0D, 0x11 | decimal |
| 0x6C | NUMERICNTYPE | 0x05, 0x09, 0x0D, 0x11 | numeric |
| 0x6D | FLTNTYPE | 0x04, 0x08 | real/float |
| 0x6E | MONEYNTYPE | 0x04, 0x08 | smallmoney/money |
| 0x6F | DATETIMNTYPE | 0x04, 0x08 | smalldatetime/datetime |
| 0x28 | DATENTYPE | 0x03 (no TYPE_VARLEN in TYPE_INFO) | date |
| 0x29 | TIMENTYPE | see scale table | time(n) |
| 0x2A | DATETIME2NTYPE | see scale table | datetime2(n) |
| 0x2B | DATETIMEOFFSETNTYPE | see scale table | datetimeoffset(n) |

Legacy BYTELEN types (TDS 7.0 compatibility):

| ID | Name | SQL Type |
|----|------|----------|
| 0x25 | VARBINARYTYPE | varbinary (legacy, max 255B) |
| 0x27 | VARCHARTYPE | varchar (legacy, max 255 chars) |
| 0x2D | BINARYTYPE | binary (legacy) |
| 0x2F | CHARTYPE | char (legacy) |

### Variable-Length Data Types (VARLENTYPE) — USHORTLEN

TYPE_VARLEN = 2 bytes LE max length. NULL = `0xFFFF` in data.

| ID | Name | SQL Type |
|----|------|----------|
| 0xA5 | BIGVARBINARYTYPE | varbinary(n) |
| 0xA7 | BIGVARCHARTYPE | varchar(n) |
| 0xAD | BIGBINARYTYPE | binary(n) |
| 0xAF | BIGCHARTYPE | char(n) |
| 0xE7 | NVARCHARTYPE | nvarchar(n) |
| 0xEF | NCHARTYPE | nchar(n) |
| 0xF5 | VECTORTYPE | vector (TDS 7.4, uses SCALE for dimension type) |

When max length = `0xFFFF` → PLP type (varchar(max), nvarchar(max), varbinary(max)).

### Variable-Length Data Types (VARLENTYPE) — LONGLEN

TYPE_VARLEN = 4 bytes LE. NULL = `0xFFFFFFFF`.

| ID | Name | SQL Type |
|----|------|----------|
| 0x22 | IMAGETYPE | image (deprecated) |
| 0x23 | TEXTTYPE | text (deprecated) |
| 0x62 | SSVARIANTTYPE | sql_variant (max 8009 bytes) |
| 0x63 | NTEXTTYPE | ntext (deprecated) |

### Partially Length-Prefixed Types (PLP / PARTLENTYPE)

Used for max types, xml, UDT, json. NULL = `0xFFFFFFFFFFFFFFFF` (8 bytes).

| ID | Name | USHORTMAXLEN in TYPE_INFO? |
|----|------|---------------------------|
| 0xF1 | XMLTYPE | No |
| 0xF0 | UDTTYPE | No |
| 0xF4 | JSONTYPE | No |
| 0xA5 | BIGVARBINARYTYPE | Yes (0xFFFF) |
| 0xA7 | BIGVARCHARTYPE | Yes (0xFFFF) |
| 0xE7 | NVARCHARTYPE | Yes (0xFFFF) |

```
PLP_BODY     = PLP_NULL / (TotalLength *PLP_CHUNK PLP_TERMINATOR)
PLP_NULL     = 0xFFFFFFFFFFFFFFFF
TotalLength  = ULONGLONG (actual length or 0xFFFFFFFFFFFFFFFE for unknown)
PLP_CHUNK    = ChunkLength(ULONG 4B LE) ChunkData(*BYTE)
PLP_TERMINATOR = 0x00000000
```

---

## 14. Data Type Encoding Details

### Integer Types

All signed integers, little-endian. Exception: **tinyint is unsigned** (0-255).

| Type | Size | Range |
|------|------|-------|
| tinyint | 1B | 0 to 255 |
| smallint | 2B | -32,768 to 32,767 |
| int | 4B | -2,147,483,648 to 2,147,483,647 |
| bigint | 8B | -9.2×10^18 to 9.2×10^18 |

### Floating Point (IEEE 754)

| Type | Size | Range |
|------|------|-------|
| real | 4B | ±3.40E+38 (7 digits precision) |
| float | 8B | ±1.79E+308 (15 digits precision) |

### Decimal/Numeric

TYPE_INFO includes PRECISION (1B) and SCALE (1B) after TYPE_VARLEN.

Wire format: `sign(1B) + value(LE integer)`. Sign: 0x01=positive, 0x00=negative.

| Precision | Wire Size |
|-----------|-----------|
| 1-9 | 1 (sign) + 4 = 5 bytes |
| 10-19 | 1 + 8 = 9 bytes |
| 20-28 | 1 + 12 = 13 bytes |
| 29-38 | 1 + 16 = 17 bytes |

### Money Types

| Type | Size | Range | Encoding |
|------|------|-------|----------|
| smallmoney | 4B | -214,748.3648 to 214,748.3647 | Signed 32-bit LE int × 10000 |
| money | 8B | ±922 trillion | **High 4B first, then low 4B** (NOT simple LE!) |

### DateTime Types

**smalldatetime** (4 bytes):
- 2B unsigned LE: days since 1900-01-01
- 2B unsigned LE: minutes since midnight
- Range: 1900-01-01 to 2079-06-06, accuracy: 1 minute

**datetime** (8 bytes):
- 4B signed LE: days since 1900-01-01 (negative = before 1900)
- 4B unsigned LE: 1/300ths of second since midnight
- Range: 1753-01-01 to 9999-12-31, accuracy: 3.33ms

**date** (3 bytes, TDS 7.3+):
- 3B unsigned LE: days since 0001-01-01
- Range: 0001-01-01 to 9999-12-31

**time(n)** (3-5 bytes, TDS 7.3+):
- Variable-size unsigned LE integer: ticks since midnight
- Tick unit = 10^(-scale) seconds (scale 0-7)
- Range: 00:00:00.0000000 to 23:59:59.9999999

**datetime2(n)** (6-8 bytes, TDS 7.3+):
- Time component (same as time(n)) + 3B date component (days since 0001-01-01)

**datetimeoffset(n)** (8-10 bytes, TDS 7.3+):
- UTC time + UTC date + 2B signed LE offset in minutes (-840 to 840, i.e.,
  -14:00 to +14:00). Decode by shifting the UTC fields by the retained offset;
  do not interpret the first fields as local civil time.
- Scale conversion rounds the UTC time and carries into the encoded date.
  Validate both local and UTC year ranges before writing.
- Example bare value at scale 7: `2026-07-01 02:30:00.1234567 +05:30` →
  `87 5E 2F 05 B0 D4 49 0B 4A 01` (5-byte UTC time, 3-byte UTC date,
  signed offset `0x014A`).

### Scale-to-Length Tables (TDS 7.3+)

**TIMENTYPE (0x29)**:

| Scale | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-------|---|---|---|---|---|---|---|---|
| Bytes | 3 | 3 | 3 | 4 | 4 | 5 | 5 | 5 |

**DATETIME2NTYPE (0x2A)** = time bytes + 3 date bytes:

| Scale | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-------|---|---|---|---|---|---|---|---|
| Bytes | 6 | 6 | 6 | 7 | 7 | 8 | 8 | 8 |

**DATETIMEOFFSETNTYPE (0x2B)** = time bytes + 3 date bytes + 2 offset bytes:

| Scale | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|-------|---|---|---|---|---|---|---|---|
| Bytes | 8 | 8 | 8 | 9 | 9 | 10 | 10 | 10 |

### UniqueIdentifier (GUID)

16 bytes, mixed-endian Microsoft GUID format:
- Bytes 0-3: Data1 (LE)
- Bytes 4-5: Data2 (LE)
- Bytes 6-7: Data3 (LE)
- Bytes 8-15: Data4 (BE / network order)

### COLLATION (5 bytes)

Sent with character types (BIGCHARTYPE, BIGVARCHARTYPE, NCHARTYPE, NVARCHARTYPE, TEXTTYPE, NTEXTTYPE).

```
Bytes 0-3: LCID(20 bits) + ColFlags(8 bits) + Version(4 bits)
Byte 4:    SortId

ColFlags (LSB order):
  Bit 0: fIgnoreCase
  Bit 1: fIgnoreAccent
  Bit 2: fIgnoreKana
  Bit 3: fIgnoreWidth
  Bit 4: fBinary
  Bit 5: fBinary2
  Bit 6: fUTF8
  Bit 7: Reserved
```

Version values: 0=SQL Server 2000, 1=2005, 2=2008, 3=2017.

### Character Strings

| Type | Max Size | TDS Encoding |
|------|----------|--------------|
| char(n) | 8,000 bytes | Collation-dependent |
| varchar(n) | 8,000 bytes | 2B length prefix + data |
| varchar(max) | 2 GB | PLP encoding |
| nchar(n) | 4,000 char-pairs | UTF-16 LE, fixed-width |
| nvarchar(n) | 4,000 char-pairs | 2B length prefix + UTF-16 LE |
| nvarchar(max) | 2 GB | PLP encoding, UTF-16 LE |

### Binary Types

| Type | Max Size | TDS Encoding |
|------|----------|--------------|
| binary(n) | 8,000 bytes | Fixed-width raw bytes |
| varbinary(n) | 8,000 bytes | 2B length prefix + raw bytes |
| varbinary(max) | 2 GB | PLP encoding |

### sql_variant (SSVARIANTTYPE 0x62)

Outer wrapper: 4-byte LE length prefix (LONGLEN). Max total **8,009 bytes**.

Cannot contain: max types, text, ntext, image, xml, timestamp, UDTs, sql_variant.

Internal structure:
```
VARIANT_BASETYPE(1B)      ; TDS type token of the base type
VARIANT_PROPBYTES(1B)     ; count of property bytes following
VARIANT_PROPERTIES(*B)    ; type-specific metadata
VARIANT_DATAVAL(1+B)      ; actual value
```

Properties by base type:
- **Numeric** (decimal/numeric): precision(1B) + scale(1B)
- **Character** (char/varchar/nchar/nvarchar): collation(5B) + max_length(2B)
- **Binary**: max_length(2B)
- **Date/time types** (time/datetime2/datetimeoffset): scale(1B)
- **Other** (int, float, datetime, etc.): no properties (PROPBYTES=0)

### VECTORTYPE (0xF5, TDS 7.4)

USHORTLEN type. In TYPE_INFO, uses SCALE (not TYPE_VARLEN) to encode dimension type. Max 8,000 bytes.

Wire format value:
```
Header (8 bytes):
  Byte 0:   Layout Format (MUST be 0xA9)
  Byte 1:   Layout Version (MUST be 0x01)
  Bytes 2-3: Number of Dimensions (USHORT LE)
  Byte 4:   Dimension Type (0x23 = float32)
  Bytes 5-7: Reserved (MUST be 0x00)

Followed by: N × sizeof(T) bytes of LE values
```

Max 1998 float32 dimensions (8 header + 1998×4 = 8000 bytes). Requires VECTORSUPPORT feature extension.

### JSONTYPE (0xF4, TDS 7.4)

PLP type (PARTLENTYPE). Data is UTF-8 encoded JSON per RFC 8259. Requires JSONSUPPORT feature extension.

### UDT_INFO (UDTTYPE 0xF0, TDS 7.2+)

CLR User-Defined Type info. PARTLENTYPE (PLP encoding).

```
; In COLMETADATA (server → client):
UDT_INFO = MAX_BYTE_SIZE(USHORT)            ; 1-8000 or 0xFFFF for Large UDT
           DB_NAME(B_VARCHAR)
           SCHEMA_NAME(B_VARCHAR)
           TYPE_NAME(B_VARCHAR)
           ASSEMBLY_QUALIFIED_NAME(US_VARCHAR)

; In RPC (client → server):
UDT_INFO = DB_NAME(B_VARCHAR) SCHEMA_NAME(B_VARCHAR) TYPE_NAME(B_VARCHAR)
```

### XML_INFO (XMLTYPE 0xF1, TDS 7.2+)

```
XML_INFO = SCHEMA_PRESENT(BYTE)
           [DbName(B_VARCHAR) OwningSchema(B_VARCHAR) XmlSchemaCollection(US_VARCHAR)]
```

SCHEMA_PRESENT: 0x01 = typed XML with schema; 0x00 = untyped XML.

### mssqlite codec status

`TypeInfo` and `Value` encode/decode native SSVARIANTTYPE, XMLTYPE, and
UDTTYPE result shapes. `SqlVariant` preserves and validates the inner base
token/properties/value; untyped XML uses `F1 00` TYPE_INFO and UTF-16LE PLP;
CLR types use full COLMETADATA UDT_INFO and opaque binary PLP values. Incoming
RPC UDT metadata has a shorter layout and remains unsupported. Tedious 18.x
also throws `not implemented` before sending XML, UDT, or Variant parameters,
so client parameter attempts fail explicitly rather than falling back to text
or varbinary.

### TextPointer and Timestamp (text/ntext/image in ROW/NBCROW)

For text/ntext/image columns:
```
ColumnData = [TextPointer Timestamp] Data(TYPE_VARBYTE)

TextPointer = B_VARBYTE       ; typically 16 bytes; 0x00 (empty) = NULL
Timestamp   = 8BYTE           ; only present when TextPointer is non-empty
```

TextPointer and Timestamp are NOT present when value is NULL. TVP_ROW does NOT use TextPointer/Timestamp.

### Always Encrypted (TDS 7.4) — Key Structures

**EK_INFO** (in CekTable within COLMETADATA):
```
EK_INFO = DatabaseId(ULONG) CekId(ULONG) CekVersion(ULONG) CekMDVersion(ULONGLONG)
          Count(BYTE) *EncryptionKeyValue

EncryptionKeyValue = EncryptedKey(US_VARBYTE) KeyStoreName(B_VARCHAR)
                     KeyPath(US_VARCHAR) AsymmetricAlgo(B_VARCHAR)
```

**CryptoMetaData** (in COLMETADATA ColumnData and RETURNVALUE):
```
CryptoMetaData = Ordinal(USHORT) UserType(ULONG) BaseTypeInfo(TYPE_INFO)
                 EncryptionAlgo(BYTE) [AlgoName(B_VARCHAR)]
                 EncryptionAlgoType(BYTE) NormVersion(BYTE)
```

### Table-Valued Parameters (TVP, TDS 7.3+)

Used within RPC requests. TVPTYPE = **0xF3**.

```
TVP_TYPE_INFO = TVPTYPE(0xF3)
                TVP_TYPENAME                  ; DbName(B_VARCHAR) + OwningSchema(B_VARCHAR) + TypeName(B_VARCHAR)
                TVP_COLMETADATA               ; 0xFFFF (null TVP) or Count(USHORT) + *TvpColumnMetaData
                [TVP_ORDER_UNIQUE(0x10)]      ; ordering/uniqueness
                [TVP_COLUMN_ORDERING(0x11)]   ; column ordering
                TVP_END_TOKEN(0x00)
                *TVP_ROW(0x01)               ; 0x01 token + column data per row
                TVP_END_TOKEN(0x00)

TvpColumnMetaData = UserType(ULONG) Flags(USHORT) TYPE_INFO ColName(B_VARCHAR)
```

Rules:
- ColName MUST be zero-length in TVP_COLMETADATA
- DbName MUST be zero-length (only OwningSchema + TypeName used)
- NBCROW MUST NOT be used in TVP row streams
- Cannot nest TVPs; NULLTYPE not allowed inside TVP
