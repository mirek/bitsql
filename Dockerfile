# Minimal bitsql image: the native host binary on a distroless glibc base.
# Build the binary first (no MoonBit toolchain inside the image):
#   moon build --target native --release
#   docker build -t bitsql .
# Multi-arch release (amd64 + arm64 cross build): scripts/docker-publish.sh
# Run:  docker run -p 1433:1433 bitsql --database app
FROM gcr.io/distroless/cc-debian12:nonroot
ARG BITSQL_BIN=_build/native/release/build/host/host.exe
COPY ${BITSQL_BIN} /bitsql
EXPOSE 1433
ENTRYPOINT ["/bitsql", "--listen", "0.0.0.0:1433"]
