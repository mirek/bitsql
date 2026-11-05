# Linux release host for scripts/docker-publish.sh on macOS. It runs natively,
# with no emulation: arm64 on Apple Silicon (Docker Desktop's Linux VM shares the
# host architecture). It holds the MoonBit toolchain pinned to the host's moonc,
# the same bookworm glibc (2.36) and gcc as scripts/xbuild, and Node for the harness.
FROM node:24-bookworm-slim
ARG MOONC_VERSION
RUN test -n "$MOONC_VERSION" \
 && apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev binutils curl ca-certificates file git \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://cli.moonbitlang.com/install/unix.sh | MOON_HOME=/moon bash -s "$MOONC_VERSION" \
 && MOON_HOME=/moon /moon/bin/moon update \
 && chmod -R a+rwX /moon
ENV MOON_HOME=/moon PATH=/moon/bin:$PATH
