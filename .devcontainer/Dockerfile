# bitsql dev container: Linux userland with the pinned MoonBit toolchain for
# hosts without a native MoonBit release (Intel macOS). Builds for the
# container's own architecture only (see CLAUDE.md, native host rule).
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# gcc/libc (and addr2line) for the native backend and profiler. No Python:
# automation is MoonBit script mode (scripts/*.mbtx).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential libssl3 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Keep in step with .github/workflows/pages.yml and docs/moonbit/VERSIONS.md
# (release tarballs are keyed by the moonc version, `+` escaped).
ARG MOON_VERSION=0.10.14%2B7d59c7ec9
ARG TARGETARCH
USER vscode
RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
      amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p "$HOME/.moon"; \
    curl --fail --location --retry 3 "https://cli.moonbitlang.com/binaries/$MOON_VERSION/moonbit-linux-$arch.tar.gz" | tar xz -C "$HOME/.moon"; \
    curl --fail --location --retry 3 "https://cli.moonbitlang.com/cores/core-$MOON_VERSION.tar.gz" | tar xz -C "$HOME/.moon/lib"; \
    chmod +x "$HOME/.moon/bin/"* "$HOME/.moon/bin/internal/tcc"; \
    "$HOME/.moon/bin/moon" -C "$HOME/.moon/lib/core" bundle --warn-list -a --target all; \
    "$HOME/.moon/bin/moon" version
ENV PATH=/home/vscode/.moon/bin:$PATH
