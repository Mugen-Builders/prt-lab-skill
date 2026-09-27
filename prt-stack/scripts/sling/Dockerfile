# Honest Dave validator ("sling node") from the official release tarball.
# The binary is statically linked against libcartesi; only libstdc++/libgomp
# from the OS are needed, so this stays a small image and works on both
# amd64 and arm64 hosts.
# debian:trixie-slim, digest-pinned (multi-arch index).
FROM debian@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
ARG TARGETARCH
ARG DAVE_VERSION=3.0.0-alpha.5
ARG NODE_SHA256_AMD64=b06486ba4b9e0aea2591d3a3950e4df38fb13ec05ce306aab6124b8bdc884957
ARG NODE_SHA256_ARM64=dcc85765b37b74776f0f9d47346c6415da01f9b37fbeb1963e2cf8755ba6c68b

RUN set -e; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl libgomp1 libstdc++6; \
    rm -rf /var/lib/apt/lists/*

RUN set -e; \
    curl -fsSL -o /tmp/node.tar.gz \
      "https://github.com/cartesi/dave/releases/download/v${DAVE_VERSION}/cartesi-rollups-prt-${DAVE_VERSION}-node-${TARGETARCH}.tar.gz"; \
    tar -xzf /tmp/node.tar.gz -C /tmp; \
    actual=$(sha256sum /tmp/cartesi-rollups-prt-node | cut -d' ' -f1); \
    case "$TARGETARCH" in \
      amd64) expected="$NODE_SHA256_AMD64" ;; \
      arm64) expected="$NODE_SHA256_ARM64" ;; \
    esac; \
    if [ -z "$expected" ]; then echo "no pinned sha256 for $TARGETARCH"; exit 1; fi; \
    if [ "$actual" != "$expected" ]; then \
      echo "sling node binary sha256 mismatch: $actual != $expected"; exit 1; \
    fi; \
    install -m755 /tmp/cartesi-rollups-prt-node /usr/local/bin/cartesi-rollups-prt-node; \
    rm -f /tmp/node.tar.gz /tmp/cartesi-rollups-prt-node

ENTRYPOINT ["/usr/local/bin/cartesi-rollups-prt-node"]
