#!/usr/bin/env bash
# Multi-arch (linux/amd64 + linux/arm64) release image for mirek/bitsql.
#
#   scripts/docker-publish.sh           build both binaries + local images, smoke test
#   scripts/docker-publish.sh --push    ... then push X.Y.Z, X.Y, latest manifest lists
#
# No buildx/binfmt on the host: `moon build` emits portable C once, then the
# moon cc/ar plan is replayed per arch inside the bitsql-xbuild container
# (bookworm gcc, cross gcc for aarch64) against that arch's MoonBit runtime
# objects. The arm64 objects come from the linux-aarch64 MoonBit release whose
# version matches the local moonc. Per-arch images are COPY-only, so the classic
# builder handles --platform without emulation; `docker manifest` joins them.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .tmp && export TMPDIR="$PWD/.tmp"  # never /tmp (see CLAUDE.md)

push=0
[[ ${1:-} == --push ]] && push=1

repo=mirek/bitsql
version=$(sed -n 's/^version = "\(.*\)"/\1/p' moon.mod)
minor=${version%.*}
moonc_version=$(moonc -v | awk '{print $1}' | sed 's/^v//')
out=_build/xarch
src=_build/native/release/build
mkdir -p "$out"

echo "== bitsql $version (moonc $moonc_version)"
moon build --target native --release

# arm64 MoonBit runtime objects, cached per moonc version.
arm_home=$out/moon-linux-aarch64-$moonc_version
if [[ ! -d $arm_home/lib ]]; then
  mkdir -p "$arm_home"
  curl -fsSL "https://cli.moonbitlang.com/binaries/${moonc_version//+/%2B}/moonbit-linux-aarch64.tar.gz" |
    tar xz -C "$arm_home" ./lib ./include
fi
diff -r "$HOME/.moon/include" "$arm_home/include" >/dev/null ||
  { echo "arm64 MoonBit headers differ from local toolchain" >&2; exit 1; }

docker build -q -t bitsql-xbuild scripts/xbuild >/dev/null

# The cc/ar commands that produce host.exe (other executables dropped).
plan=$(moon build --target native --release --dry-run 2>/dev/null |
  grep -E '^/usr/bin/(cc|ar) ' | grep -vE -- '-o \S+\.exe ' || true)
plan+=$'\n'$(moon build --target native --release --dry-run 2>/dev/null |
  grep -E '^/usr/bin/cc -o \S+/host/host\.exe ')

build_arch() {
  local arch=$1 cc ar home
  case $arch in
    amd64) cc=gcc; ar=ar; home=$HOME/.moon ;;
    arm64) cc=aarch64-linux-gnu-gcc; ar=aarch64-linux-gnu-ar; home=$PWD/$arm_home ;;
  esac
  local dst=$out/$arch/build
  rm -rf "$dst" && mkdir -p "$dst"
  (cd "$src" && find . -name '*.c' -exec cp --parents {} "$OLDPWD/$dst" \;)
  find "$src" -type d -printf '%P\n' | (cd "$dst" && xargs -r mkdir -p)
  printf '%s\n' "$plan" | sed \
    -e "s#\./$src/#./$dst/#g" \
    -e "s#^/usr/bin/cc #$cc #" -e "s#^/usr/bin/ar #$ar #" \
    -e "s#\\\$MOON_HOME#/moon#g" >"$out/$arch/plan.sh"
  docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src" -v "$home:/moon:ro" -w /src \
    bitsql-xbuild sh -e "$out/$arch/plan.sh"
  rm -f "$out/$arch/bitsql" && cp "$dst/host/host.exe" "$out/$arch/bitsql"
  echo "== $arch: $(file -b "$out/$arch/bitsql" | cut -d, -f1-2), $(du -h "$out/$arch/bitsql" | cut -f1)"
}
build_arch amd64
build_arch arm64

# Smoke: the client test suite (npm test, one fresh server per test file)
# against each binary; arm64 runs under a static qemu-aarch64 copied out of
# bitsql-xbuild, with the cross glibc as its sysroot (no host binfmt needed).
qemu_dir=$out/qemu
if [[ ! -x $qemu_dir/qemu-aarch64-static ]]; then
  rm -rf "$qemu_dir" && mkdir -p "$qemu_dir"
  docker run --rm --user "$(id -u):$(id -g)" -v "$PWD/$qemu_dir:/out" bitsql-xbuild \
    sh -c 'cp /usr/bin/qemu-aarch64-static /out/ && cp -a /opt/arm64-sysroot /out/sysroot'
fi
printf '#!/bin/sh\nexec "%s" -L "%s" "%s" "$@"\n' \
  "$PWD/$qemu_dir/qemu-aarch64-static" "$PWD/$qemu_dir/sysroot" "$PWD/$out/arm64/bitsql" \
  >"$out/arm64/bitsql-qemu"
chmod +x "$out/arm64/bitsql-qemu"
smoke() {
  local arch=$1 bin=$2 log
  log=$(cd harness && BITSQL_BIN="$bin" npm test --silent 2>&1) ||
    { echo "$log" | tail -40; echo "== $arch smoke FAILED" >&2; exit 1; }
  grep -q '^SKIP' <<<"$log" && { echo "$log" | head; echo "== $arch smoke skipped" >&2; exit 1; }
  echo "== $arch smoke: $(grep -E '^ℹ (pass|fail|skipped) ' <<<"$log" | tr '\n' ' ')"
}
if [[ ${SKIP_SMOKE:-0} != 1 ]]; then
  smoke amd64 "$PWD/$out/amd64/bitsql"
  smoke arm64 "$PWD/$out/arm64/bitsql-qemu"
fi

for arch in amd64 arm64; do
  docker build -q --platform "linux/$arch" --build-arg "BITSQL_BIN=$out/$arch/bitsql" \
    -t "$repo:$version-$arch" . >/dev/null
done
echo "== images: $repo:$version-amd64, $repo:$version-arm64"

if ((push)); then
  for arch in amd64 arm64; do docker push -q "$repo:$version-$arch"; done
  for tag in "$version" "$minor" latest; do
    docker manifest rm "$repo:$tag" >/dev/null 2>&1 || true
    docker manifest create "$repo:$tag" "$repo:$version-amd64" "$repo:$version-arm64" >/dev/null
    docker manifest push --purge "$repo:$tag"
  done
  docker manifest inspect "$repo:$version" | grep -E '"architecture"'
fi
