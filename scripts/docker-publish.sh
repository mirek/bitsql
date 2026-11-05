#!/usr/bin/env bash
# Native-host release image for mirek/bitsql; opt-in amd64+arm64 publication.
#   scripts/docker-publish.sh          build and test this host's architecture
#   scripts/docker-publish.sh --push   publish it and update version aliases
#   scripts/docker-publish.sh --push --multiarch  cross-build ARM64, test native only
#   LOCAL_TAG=bitsql:dev scripts/docker-publish.sh   a local image only (no --push)
#   PGO=0 ...                          skip the profile-guided rebuild
# On macOS the binary (moon build, gcc, PGO, client suite) is made in a native
# Linux container (scripts/release-host: arm64 on Apple Silicon, no emulation);
# the image, scan, TLS smoke and push then run on the Mac.
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

if [[ -n ${LOCAL_TAG:-} ]] && ((push)); then
  echo "LOCAL_TAG builds a local image only; drop --push" >&2; exit 2
fi
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
mkdir -p "$out"
# builder=1: this is the Linux release host container started below on macOS;
# it makes and tests the binary only, compiling directly instead of via xbuild.
builder=${BITSQL_RELEASE_BUILDER:-0}
# A separate target dir keeps Linux build state apart from macOS's _build/native.
target=_build
((builder)) && target=_build/linux
src=$target/native/release/build

echo "== bitsql $version (moonc $moonc_version)"
if [[ $(uname -s) == Darwin ]]; then
  ((multiarch)) && { echo "--multiarch is not supported on macOS" >&2; exit 2; }
  # gcc -O2 on the 64 MB generated host.c peaks at ~2.0 GiB (measured 2026-11-05)
  mem=$(docker info --format '{{.MemTotal}}')
  ((mem >= 4 * 1024 ** 3)) || { echo "Docker VM has $((mem / 1024 ** 2)) MiB; give it 4 GiB or more" \
    "(colima stop && colima start --memory 8)" >&2; exit 1; }
  docker build -q --build-arg "MOONC_VERSION=$moonc_version" \
    -t "bitsql-release-host:${moonc_version//+/-}" scripts/release-host >/dev/null
  [[ -d harness/node_modules ]] || (cd harness && npm ci --silent --no-audit --no-fund)
  # --hostname: tedious sends os.hostname() as the workstation, and corpus
  # sysprocs/sp-who was captured on the host named linux
  docker run --rm --name "bitsql-release-host-$$" --hostname linux --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e BITSQL_RELEASE_BUILDER=1 -e PGO -e SKIP_SMOKE \
    -v "$PWD:/src" -w /src "bitsql-release-host:${moonc_version//+/-}" scripts/docker-publish.sh
else
moon build --target native --release --target-dir "$target"

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
((builder)) || docker build -q --build-arg "CROSS_ARM64=$multiarch" -t bitsql-xbuild scripts/xbuild >/dev/null

# The cc/ar commands that produce host.exe (other executables dropped).
plan=$(moon build --target native --release --target-dir "$target" --dry-run 2>/dev/null |
  grep -E '^/usr/bin/(cc|ar) ' | grep -vE -- '-o \S+\.exe ' || true)
plan+=$'\n'$(moon build --target native --release --target-dir "$target" --dry-run 2>/dev/null |
  grep -E '^/usr/bin/cc -o \S+/host/host\.exe ')
# moon 0.10.14's dry-run prints a dependency's C stubs without its source dir
# (`.mooncakes/moonbitlang/async./types/stub.c` for `source = "src"`); the
# real build resolves it, so the replayed plan restores it.
for mod in .mooncakes/*/*/moon.mod; do
  dir=${mod%/moon.mod} srcdir=$(sed -n 's/^source = "\(.*\)"/\1/p' "$mod")
  [[ -n $srcdir ]] && plan=${plan//"./$dir./"/"./$dir/$srcdir/"}
done

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
  xbuild "$moon_runtime" "$out/$arch/plan.sh"
  rm -f "$out/$arch/bitsql" && cp "$dst/host/host.exe" "$out/$arch/bitsql"
  echo "== $arch: $(file -b "$out/$arch/bitsql" | cut -d, -f1-2), $(du -h "$out/$arch/bitsql" | cut -f1)"
}
xbuild() {
  # the plan's paths are /src (this checkout) and /moon (the MoonBit runtime),
  # which the release host container already has
  if ((builder)); then sh -e "$2"; return; fi
  docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src" -v "$1:/moon:ro" -w /src \
    bitsql-xbuild sh -e "$2"
}
for arch in "${arches[@]}"; do build_arch "$arch"; done

# Profile-guided optimization of the host-architecture binary (PGO=0 skips):
# an instrumented build runs the client suite and the benchmark workloads
# natively, then host.c is compiled again with that profile. It changes code
# layout, inlining and branch decisions only; flags such as -ffp-contract=off
# stay. Point reads: ~30 → ~23 µs server CPU (decisions.md 2026-10-25).
pgo_arch() {
  local arch=$1 dst=$out/$arch/build prof=$out/$arch/pgo line bin
  rm -rf "$prof" && mkdir -p "$prof"
  line=$(grep -E ' -o \./[^ ]*/host/host\.exe ' "$out/$arch/plan.sh")
  printf '%s\n' "$line" | sed \
    -e "s# -O2 # -O2 -fprofile-generate -fprofile-update=single -fprofile-dir=/src/$prof #" \
    -e "s#\(-o \./[^ ]*/host/host\.exe\)#\1 ./scripts/pgo/exit_on_term.c#" >"$out/$arch/pgo-gen.sh"
  xbuild "$HOME/.moon" "$out/$arch/pgo-gen.sh"
  bin=$PWD/$out/$arch/bitsql-pgo-gen
  cp "$dst/host/host.exe" "$bin"
  # the profile's compiled-in path is under /src (the build container's
  # mount of this checkout): written here instead
  (
    cd harness
    export GCOV_PREFIX="$PWD/.." GCOV_PREFIX_STRIP=1 BITSQL_BIN="$bin"
    npm test --silent || true
    REPS=3 node bench/points.mjs
    WORKLOAD=requests REPS=3 node bench/profile.mjs
    REPS=5 node bench/profile.mjs
  ) >/dev/null 2>&1
  rm -f "$bin"
  [[ -n $(find "$prof" -name '*.gcda' | head -n 1) ]] || { echo "PGO: no profile was written" >&2; exit 1; }
  printf '%s\n' "$line" | sed \
    -e "s# -O2 # -O2 -fprofile-use -fprofile-partial-training -Wno-missing-profile -fprofile-dir=/src/$prof #" \
    >"$out/$arch/pgo-use.sh"
  xbuild "$HOME/.moon" "$out/$arch/pgo-use.sh"
  rm -f "$out/$arch/bitsql" && cp "$dst/host/host.exe" "$out/$arch/bitsql"
  echo "== $arch: profile-guided build, $(du -h "$out/$arch/bitsql" | cut -f1)"
}
if [[ ${PGO:-1} == 1 ]]; then pgo_arch "$host_arch"; fi

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
((builder)) && exit 0
fi  # Linux binary phase

# Hardened runtime base (scripts/base/apko.yaml): built per architecture with
# apko from Wolfi packages. apko only downloads and unpacks packages, so it
# runs nothing foreign. Each arch gets its own local tag, which the classic
# builder cannot confuse with another architecture's cached image.
apko_image=cgr.dev/chainguard/apko:latest
for arch in "${arches[@]}"; do
  case $arch in amd64) apko_arch=x86_64 ;; arm64) apko_arch=aarch64 ;; esac
  rm -rf "$out/base" && mkdir -p "$out/base"
  docker run --rm --name "bitsql-apko-$$" --user "$(id -u):$(id -g)" -e HOME=/work/_build/xarch/base \
    -v "$PWD:/work" -w /work "$apko_image" build --arch "$apko_arch" \
    --sbom-path "$out/base" scripts/base/apko.yaml "bitsql-base:$version" "$out/base/base.tar" >/dev/null 2>&1 ||
    { echo "apko: building the $arch base failed" >&2; exit 1; }
  docker load -q -i "$out/base/base.tar" >/dev/null
  rm -rf "$out/base"
  docker build -q --platform "linux/$arch" --build-arg "BASE=bitsql-base:$version-$arch" \
    --build-arg "BITSQL_BIN=$out/$arch/bitsql" \
    --label "org.opencontainers.image.version=$version" \
    --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
    --label "org.opencontainers.image.title=bitsql" \
    -t "${LOCAL_TAG:-$repo:$version-$arch}" . >/dev/null
  [[ $(docker image inspect -f '{{.Architecture}}' "${LOCAL_TAG:-$repo:$version-$arch}") == "$arch" ]] ||
    { echo "image $repo:$version-$arch has the wrong architecture" >&2; exit 1; }
done
echo "== images: ${arches[*]} ($version); runtime-tested architecture: $host_arch"

# Vulnerability gate (trivy + grype): no fixable HIGH/CRITICAL finding ships.
for arch in "${arches[@]}"; do
  LOCAL=1 scripts/image-scan.sh "${LOCAL_TAG:-$repo:$version-$arch}" | sed "s/^== local/== $arch scan/"
done

# The image itself (base libraries included) must accept an encrypted login.
image=${LOCAL_TAG:-$repo:$version-$host_arch}
cid=$(docker run -d --rm --name "bitsql-publish-smoke-$$" -p 127.0.0.1::1433 "$image")
trap 'docker stop "$cid" >/dev/null 2>&1 || true' EXIT
port=$(docker port "$cid" 1433/tcp | head -n 1 | sed 's/.*://')
(cd harness && node -e '
const { Connection, Request } = require("tedious")
const port = Number(process.argv[1])
const c = new Connection({ server: "127.0.0.1",
  authentication: { type: "default", options: { userName: "sa", password: "x" } },
  options: { port, encrypt: true, trustServerCertificate: true, connectTimeout: 5000 } })
c.on("connect", err => {
  if (err) { console.error(err.message); process.exit(1) }
  let enc = null
  const r = new Request("select encrypt_option from sys.dm_exec_connections where session_id = @@spid", err => {
    c.close()
    if (err || enc !== "TRUE") { console.error(err?.message ?? "not encrypted: " + enc); process.exit(1) }
  })
  r.on("row", cols => { enc = cols[0].value })
  c.execSql(r)
})
c.connect()' "$port") || { docker logs "$cid" 2>&1 | tail -20; echo "== $host_arch image TLS smoke FAILED" >&2; exit 1; }
docker stop "$cid" >/dev/null && trap - EXIT
echo "== $host_arch image: encrypted login OK"

if ((push)); then
  published=()
  for arch in "${arches[@]}"; do
    docker push -q "$repo:$version-$arch"
    published+=("$repo:$version-$arch")
  done
  # Preserve only other architectures already validated for this version.
  # A registry/network error must not silently erase their manifest entries.
  if existing=$(docker manifest inspect "$repo:$version" 2>&1); then
    references=$(node -e '
const [arches, repo] = process.argv.slice(1)
const index = JSON.parse(require("fs").readFileSync(0, "utf8"))
for (const entry of index.manifests ?? [])
  if (!arches.split(/\s+/).includes(entry.platform.architecture))
    console.log(repo + "@" + entry.digest)
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
