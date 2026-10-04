# Cross-build toolchain for the release binaries (scripts/docker-publish.sh).
# Bookworm matches the glibc (2.36) of the distroless/cc-debian12 runtime base.
# qemu-user-static plus /opt/arm64-sysroot (cross glibc + libssl3:arm64, which
# the TLS layer dlopens) run the arm64 binary for the smoke test without host
# binfmt setup.
FROM debian:bookworm-slim
RUN dpkg --add-architecture arm64 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc libc6-dev binutils \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu \
      qemu-user-static \
 && cd /tmp && apt-get download libssl3:arm64 \
 && cp -a /usr/aarch64-linux-gnu /opt/arm64-sysroot \
 && dpkg -x libssl3_*_arm64.deb /tmp/ssl \
 && cp -a /tmp/ssl/usr/lib/aarch64-linux-gnu/. /opt/arm64-sysroot/lib/ \
 && rm -rf /tmp/ssl /tmp/*.deb /var/lib/apt/lists/*
