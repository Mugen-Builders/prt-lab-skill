# Fraudulent-player ("sybil") image for Dave PRT tournaments.
#
# Deliberately light: the Lua dispute client needs only lua5.4, the `cartesi`
# Lua module (shipped inside the emulator .deb - no source build), `cast`, and
# `jq`. It does NOT need sqlite3, the Rust workspace, or the machine-emulator
# submodule; those are for dave's own e2e harness, not for playing a tournament.
# debian:trixie-slim, digest-pinned (multi-arch index).
FROM debian@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
ARG TARGETARCH
ARG EMULATOR_VERSION=0.21.0
ARG FOUNDRY_VERSION=1.5.1

RUN set -e; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl jq lua5.4 lua-lpeg libslirp0 libgomp1; \
    rm -rf /var/lib/apt/lists/*

# Cartesi Machine emulator (CLI + libcartesi + /usr/lib/lua/5.4/cartesi.so).
# Checksums are the ones rollups-node/Dockerfile pins for the same release.
RUN set -e; \
    curl -fsSL -o /tmp/me.deb \
      "https://github.com/cartesi/machine-emulator/releases/download/v${EMULATOR_VERSION}/machine-emulator_${TARGETARCH}.deb"; \
    case "$TARGETARCH" in \
      amd64) echo "5f13034f43454c340062c677146daabe77c587cee1bd60342c95b8ad8f1463a3  /tmp/me.deb" | sha256sum -c ;; \
      arm64) echo "866f0bde2db53b9b8e6a6eac85e5ad4116338379fa25cdfcc5e4bf835f948bb1  /tmp/me.deb" | sha256sum -c ;; \
      *) echo "unsupported arch $TARGETARCH"; exit 1 ;; \
    esac; \
    dpkg -i /tmp/me.deb; rm /tmp/me.deb

# Foundry (cast/anvil). Same pin and checksums as dave's test/Dockerfile.
RUN set -e; \
    curl -fsSL -o /tmp/foundry.tar.gz \
      "https://github.com/foundry-rs/foundry/releases/download/v${FOUNDRY_VERSION}/foundry_v${FOUNDRY_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    case "$TARGETARCH" in \
      amd64) echo "73640b01bd9ed29fdb4965085099371f8cf0dbbec3e2086cf54564efc4dcfe88  /tmp/foundry.tar.gz" | sha256sum -c ;; \
      arm64) echo "cccf28bdf202289e837a9e21ed213b2b80dc1e806e12f1717bc98a44315c331e  /tmp/foundry.tar.gz" | sha256sum -c ;; \
    esac; \
    tar -zxf /tmp/foundry.tar.gz -C /usr/local/bin cast anvil; rm /tmp/foundry.tar.gz

# Dave's Lua dispute client + the e2e support code it reuses (sybil runner,
# patched commitment builder, chain reader). The build context is assembled
# by lib.sh (build_sybil_image) under $PRT_WORKSPACE/build/sybil from
# `git archive` of the pinned dave commit, so the context stays tiny and
# the installed skill directory is never written to.
COPY prt/client-lua        /dave/prt/client-lua
COPY test/e2e/support      /dave/test/e2e/support
COPY test/e2e/rollups/dave /dave/test/e2e/rollups/dave
COPY sybils.lua            /dave/sybils.lua
COPY DAVE_REV              /dave/DAVE_REV

ENV LUA_PATH="/dave/test/e2e/support/?.lua;/dave/prt/client-lua/?.lua;/dave/test/e2e/rollups/?.lua;/usr/share/lua/5.4/?.lua;/usr/share/lua/5.4/?/init.lua;;"
ENV LUA_CPATH="/usr/lib/lua/5.4/?.so;/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/usr/lib/aarch64-linux-gnu/lua/5.4/?.so;;"
WORKDIR /dave
ENTRYPOINT ["lua5.4", "/dave/sybils.lua"]
