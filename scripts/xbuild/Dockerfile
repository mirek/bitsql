# Native release compiler; build on the same architecture as the runtime.
# Bookworm matches glibc 2.36 in distroless/cc-debian12.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev binutils \
 && rm -rf /var/lib/apt/lists/*
