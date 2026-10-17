# Third-party notices

bitsql's own code and documentation are dedicated to the public domain under
[CC0 1.0](LICENSE.md). The parts listed here are by other authors and keep
their own licenses. The CC0 dedication does not cover them.

## Compiled into the `bitsql` binary, the Docker image and the browser engine

| Component | License | Text |
| --- | --- | --- |
| [moonbitlang/core](https://github.com/moonbitlang/core) (MoonBit standard library) | Apache-2.0 | [licenses/Apache-2.0.txt](licenses/Apache-2.0.txt), NOTICE: [licenses/moonbitlang-core-NOTICE.txt](licenses/moonbitlang-core-NOTICE.txt) (includes fdlibm, V8 and Go BSD notices and the Arm MIT notice) |
| [moonbitlang/async](https://github.com/moonbitlang/async) 0.22.4 (native host only) | Apache-2.0 | [licenses/Apache-2.0.txt](licenses/Apache-2.0.txt) |
| RE2 Unicode tables ([google/re2](https://github.com/google/re2)), generated into `src/core` | BSD-3-Clause | [docs/reference/vendor/re2/LICENSE](docs/reference/vendor/re2/LICENSE) |

`licenses/moonbitlang-core-NOTICE.txt` is taken from moonbitlang/core
`eb321a18f7a33d37114546682a8d1cd6658afab8`.

The native host loads OpenSSL (`libssl`) dynamically at runtime from the
system. It isn't linked into the binary. In the Docker image it comes from the
distroless Debian base image, under that image's own licenses.

## Vendored documentation (not shipped)

`docs/moonbit/` holds MoonBit documentation copied for local reference by
`scripts/update-moonbit-docs.mbtx`. It keeps its upstream licenses (see
[docs/moonbit/LICENSES.md](docs/moonbit/LICENSES.md)) and is not covered by
the CC0 dedication.

## Trademarks

Microsoft and SQL Server are trademarks of the Microsoft group of companies.
bitsql is an independent project. It is not affiliated with, endorsed by or
sponsored by Microsoft. "SQL Server" is used only to describe the system
bitsql emulates and is compatible with.
