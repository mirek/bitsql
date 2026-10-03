# Minimal bitsql image: the native host binary on a distroless glibc base.
# Build the binary first (no MoonBit toolchain inside the image):
#   moon build --target native --release
#   docker build -t bitsql .
# Run:  docker run -p 1433:1433 bitsql --database app
FROM gcr.io/distroless/cc-debian12:nonroot
COPY _build/native/release/build/host/host.exe /bitsql
EXPOSE 1433
ENTRYPOINT ["/bitsql", "--listen", "0.0.0.0:1433"]
