# Minimal bitsql image: the native host binary on a distroless glibc base.
# Build the binary first (no MoonBit toolchain inside the image):
#   moon build --target native --release
#   docker build -t bitsql .
# Native-host release (run separately on each architecture): scripts/docker-publish.sh
# Run:  docker run -p 1433:1433 bitsql --database app
# BASE: scripts/docker-publish.sh pins each arch's digest (the classic
# builder would otherwise reuse the locally cached amd64 image for arm64).
ARG BASE=gcr.io/distroless/cc-debian12:nonroot
FROM ${BASE}
ARG BITSQL_BIN=_build/native/release/build/host/host.exe
COPY ${BITSQL_BIN} /bitsql
COPY docs/reference/vendor/re2/LICENSE /usr/share/licenses/bitsql/re2-LICENSE
EXPOSE 1433
ENTRYPOINT ["/bitsql", "--listen", "0.0.0.0:1433"]
