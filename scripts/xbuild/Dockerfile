# Bookworm matches glibc 2.36 in distroless/cc-debian12.
# Cross compiler is opt-in; no QEMU or foreign executable runs here.
FROM debian:bookworm-slim
ARG CROSS_ARM64=0
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev binutils \
 && if [ "$CROSS_ARM64" = 1 ]; then apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu; fi \
 && rm -rf /var/lib/apt/lists/*
