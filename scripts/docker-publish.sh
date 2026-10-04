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
# Every cc call gets -ffp-contract=off: GCC on aarch64 fuses a*b+c into fma
# by default, which skips a rounding and diverges from SQL Server's float
# results (x86-64 has no implicit FMA). The arm64 smoke caught it (VAR over
# equal decimals 2204 instead of 0). moon.pkg `cc-flags` can't carry it: it
# replaces moon's defaults (drops -O2 and the debug flags).
set -euo pipefail
cd "$(dirname "$0")/.."

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
    -e "s#^/usr/bin/cc #$cc -ffp-contract=off #" -e "s#^/usr/bin/ar #$ar #" \
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
# arm64 under qemu takes about an hour for the full suite, and the binary is
# the same C as amd64, so by default it gets a quick smoke: corpus/smoke plus
# the allowlisted cases where the arch can show (float math, conversions:
# FMA contraction diverged there), all over TLS logins. FULL_ARM64_SMOKE=1
# runs the whole client suite instead.
smoke_arm64_quick() {
  local bin=$1 log
  local -a sel=(smoke)
  mapfile -t -O 1 sel < <(sed 's/\s\+#\s.*$//' harness/allowlist.txt |
    grep -E '^(analytic|conversion|msduck-runs/statistical)')
  log=$(cd harness && BITSQL_BIN="$bin" npm run --silent diff -- "${sel[@]}" 2>&1)
  local summary
  summary=$(grep -E '^emulator: ' <<<"$log")
  grep -qE '^emulator: [0-9]+/[0-9]+ passed, 0 failed' <<<"$summary" ||
    { echo "$log" | tail -40; echo "== arm64 smoke FAILED" >&2; exit 1; }
  echo "== arm64 quick smoke (${#sel[@]} selectors): $summary"
}
if [[ ${SKIP_SMOKE:-0} != 1 ]]; then
  smoke amd64 "$PWD/$out/amd64/bitsql"
  if [[ ${FULL_ARM64_SMOKE:-0} == 1 ]]; then
    smoke arm64 "$PWD/$out/arm64/bitsql-qemu"
  else
    smoke_arm64_quick "$PWD/$out/arm64/bitsql-qemu"
  fi
fi

# The base is pinned per arch by digest: given a tag, the classic builder
# reuses whatever arch is cached locally (amd64) even with --platform.
base=gcr.io/distroless/cc-debian12
base_index=$(docker manifest inspect "$base:nonroot")
for arch in amd64 arm64; do
  digest=$(python3 -c "import json,sys; print(next(m['digest'] for m in json.load(sys.stdin)['manifests'] if m['platform']['architecture'] == sys.argv[1]))" "$arch" <<<"$base_index")
  docker pull -q --platform "linux/$arch" "$base@$digest" >/dev/null
  docker build -q --platform "linux/$arch" --build-arg "BASE=$base@$digest" \
    --build-arg "BITSQL_BIN=$out/$arch/bitsql" \
    --label "org.opencontainers.image.version=$version" \
    --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
    --label "org.opencontainers.image.title=bitsql" \
    -t "$repo:$version-$arch" . >/dev/null
  [[ $(docker image inspect -f '{{.Architecture}}' "$repo:$version-$arch") == "$arch" ]] ||
    { echo "image $repo:$version-$arch has the wrong architecture" >&2; exit 1; }
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
