#!/usr/bin/env bash
# Native-host release image for mirek/bitsql; opt-in amd64+arm64 publication.
#   scripts/docker-publish.sh          build and test this host's architecture
#   scripts/docker-publish.sh --push   publish it and update version aliases
#   scripts/docker-publish.sh --push --multiarch  cross-build ARM64, test native only
# Other architectures are built/tested on their own native hosts. Publication
# preserves architectures already published under the SAME version; coordinate
# manifest updates across hosts. Never mix binaries from different versions.
# Keep -ffp-contract=off: fused ARM64 operations differ from captured SQL floats.
set -euo pipefail
cd "$(dirname "$0")/.."

push=0
multiarch=0
for arg in "$@"; do
  case $arg in
    --push) push=1 ;;
    --multiarch) multiarch=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

repo=mirek/bitsql
version=$(sed -n 's/^version = "\(.*\)"/\1/p' moon.mod)
minor=${version%.*}
case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "Unsupported native architecture: $(uname -m)" >&2; exit 1 ;;
esac
host_arch=$arch
arches=("$host_arch")
if ((multiarch)); then
  [[ $host_arch == amd64 ]] || { echo "--multiarch cross-build requires an amd64 host" >&2; exit 2; }
  arches=(amd64 arm64)
fi
moonc_version=$(moonc -v | awk '{print $1}' | sed 's/^v//')
out=_build/xarch
src=_build/native/release/build
mkdir -p "$out"

echo "== bitsql $version (moonc $moonc_version)"
moon build --target native --release

# Explicit --multiarch permits cross-compilation, never emulated execution.
arm_home=$out/moon-linux-aarch64-$moonc_version
if ((multiarch)); then
  if [[ ! -d $arm_home/lib ]]; then
    mkdir -p "$arm_home"
    if ! curl -fsSL "https://cli.moonbitlang.com/binaries/${moonc_version//+/%2B}/moonbit-linux-aarch64.tar.gz" |
      tar xz -C "$arm_home" ./lib ./include; then
      rm -rf "$arm_home"
      exit 1
    fi
  fi
  diff -r "$HOME/.moon/include" "$arm_home/include" >/dev/null ||
    { echo "ARM64 MoonBit headers differ from local toolchain" >&2; exit 1; }
fi
docker build -q --build-arg "CROSS_ARM64=$multiarch" -t bitsql-xbuild scripts/xbuild >/dev/null

# The cc/ar commands that produce host.exe (other executables dropped).
plan=$(moon build --target native --release --dry-run 2>/dev/null |
  grep -E '^/usr/bin/(cc|ar) ' | grep -vE -- '-o \S+\.exe ' || true)
plan+=$'\n'$(moon build --target native --release --dry-run 2>/dev/null |
  grep -E '^/usr/bin/cc -o \S+/host/host\.exe ')

build_arch() {
  local arch=$1 cc=gcc ar=ar moon_runtime=$HOME/.moon
  if [[ $arch != "$host_arch" ]]; then
    cc=aarch64-linux-gnu-gcc
    ar=aarch64-linux-gnu-ar
    moon_runtime=$PWD/$arm_home
  fi
  local dst=$out/$arch/build
  rm -rf "$dst" && mkdir -p "$dst"
  (cd "$src" && find . -name '*.c' -exec cp --parents {} "$OLDPWD/$dst" \;)
  find "$src" -type d -printf '%P\n' | (cd "$dst" && xargs -r mkdir -p)
  printf '%s\n' "$plan" | sed \
    -e "s#\./$src/#./$dst/#g" \
    -e "s#^/usr/bin/cc #$cc -ffp-contract=off #" -e "s#^/usr/bin/ar #$ar #" \
    -e "s#\\\$MOON_HOME#/moon#g" >"$out/$arch/plan.sh"
  docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src" -v "$moon_runtime:/moon:ro" -w /src \
    bitsql-xbuild sh -e "$out/$arch/plan.sh"
  rm -f "$out/$arch/bitsql" && cp "$dst/host/host.exe" "$out/$arch/bitsql"
  echo "== $arch: $(file -b "$out/$arch/bitsql" | cut -d, -f1-2), $(du -h "$out/$arch/bitsql" | cut -f1)"
}
for arch in "${arches[@]}"; do build_arch "$arch"; done

# The full client suite runs directly on the host architecture.
smoke() {
  local arch=$1 bin=$2 log
  log=$(cd harness && BITSQL_BIN="$bin" npm test --silent 2>&1) ||
    { echo "$log" | tail -40; echo "== $arch smoke FAILED" >&2; exit 1; }
  grep -q '^SKIP' <<<"$log" && { echo "$log" | head; echo "== $arch smoke skipped" >&2; exit 1; }
  echo "== $arch smoke: $(grep -E '^ℹ (pass|fail|skipped) ' <<<"$log" | tr '\n' ' ')"
}
if [[ ${SKIP_SMOKE:-0} != 1 ]]; then
  smoke "$host_arch" "$PWD/$out/$host_arch/bitsql"
fi

# The base is pinned per arch by digest: given a tag, the classic builder
# can reuse whichever architecture is cached locally even with --platform.
base=gcr.io/distroless/cc-debian12
base_index=$(docker manifest inspect "$base:nonroot")
for arch in "${arches[@]}"; do
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
echo "== images: ${arches[*]} ($version); runtime-tested architecture: $host_arch"

if ((push)); then
  published=()
  for arch in "${arches[@]}"; do
    docker push -q "$repo:$version-$arch"
    published+=("$repo:$version-$arch")
  done
  # Preserve only other architectures already validated for this version.
  # A registry/network error must not silently erase their manifest entries.
  if existing=$(docker manifest inspect "$repo:$version" 2>&1); then
    references=$(python3 -c '
import json,sys
index=json.load(sys.stdin)
for entry in index.get("manifests", []):
    if entry["platform"]["architecture"] not in sys.argv[1].split():
        print(sys.argv[2] + "@" + entry["digest"])
' "${arches[*]}" "$repo" <<<"$existing")
    previous=()
    if [[ -n $references ]]; then mapfile -t previous <<<"$references"; fi
  elif [[ $existing == *"no such manifest"* || $existing == *"manifest unknown"* ]]; then
    previous=()
  else
    echo "$existing" >&2
    exit 1
  fi
  for tag in "$version" "$minor" latest; do
    docker manifest rm "$repo:$tag" >/dev/null 2>&1 || true
    docker manifest create "$repo:$tag" "${published[@]}" "${previous[@]}" >/dev/null
    docker manifest push --purge "$repo:$tag"
  done
  docker manifest inspect "$repo:$version" | grep -E '"architecture"'
fi
