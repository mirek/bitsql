# Minimal bitsql image: the native host binary on a hardened Wolfi base
# (glibc + CA certificates + OpenSSL, no shell), built with apko from
# scripts/base/apko.yaml. Build the binary first (no MoonBit toolchain
# inside the image):
#   moon build --target native --release
#   docker run --rm -e HOME=/work/_build -v "$PWD:/work" -w /work --user "$(id -u):$(id -g)" \
#     cgr.dev/chainguard/apko build --arch x86_64 scripts/base/apko.yaml bitsql-base _build/base.tar
#   docker load -i _build/base.tar && rm _build/base.tar   # tags bitsql-base:latest-amd64
#   docker build --build-arg BASE=bitsql-base:latest-amd64 -t bitsql .
# Native-host release (run separately on each architecture), which does all
# of the above and scans the result: scripts/docker-publish.sh
# Run:  docker run -p 1433:1433 bitsql --database app
ARG BASE=bitsql-base:latest-amd64
FROM ${BASE}
ARG BITSQL_BIN=_build/native/release/build/host/host.exe
COPY ${BITSQL_BIN} /bitsql
COPY LICENSE.md THIRD_PARTY_NOTICES.md /usr/share/licenses/bitsql/
COPY licenses/ /usr/share/licenses/bitsql/licenses/
COPY docs/reference/vendor/re2/LICENSE /usr/share/licenses/bitsql/re2-LICENSE
EXPOSE 1433
ENTRYPOINT ["/bitsql", "--listen", "0.0.0.0:1433"]
