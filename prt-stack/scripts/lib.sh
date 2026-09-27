#!/usr/bin/env bash
# Shared helpers for prt-stack.sh. Sourced, not executed.
#
# Design rules that keep this portable:
#   * the host needs only bash, docker (compose v2), curl, git and the usual
#     POSIX utilities (tar, sed, awk, grep, od). Every other tool (cast, anvil,
#     jq, cartesi-machine, lua) runs inside an image.
#   * nothing is hardcoded to a machine: release assets are fetched by version
#     into $PRT_WORKSPACE and verified by checksum on every use, contract
#     addresses are read from the dump's deployment records, keys are derived
#     from anvil's default mnemonic.
#   * the installed skill directory is never written to; all state, build
#     contexts and caches live under $PRT_WORKSPACE.

set -euo pipefail

SKILL_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- configuration (all overridable from the environment) -------------------
: "${PRT_WORKSPACE:=$PWD/prt-stack-workspace}"
: "${PRT_PROJECT:=prt-stack}"
: "${PRT_DAVE_VERSION:=3.0.0-alpha.5}"
: "${PRT_FOUNDRY_VERSION:=1.5.1}"
: "${PRT_DUMP_SHA256:=7e6b6a402b5e384fd6aa56387726cf4cc08783b6350b1c16a71a2e6ff454e583}"
: "${PRT_SYBIL_IMAGE:=prt-sybil:${PRT_DAVE_VERSION}}"
: "${PRT_SLING_IMAGE:=prt-sling:${PRT_DAVE_VERSION}}"
: "${PRT_NODE_IMAGE:=prt-node:local}"
: "${PRT_NODE_REPO:=}"                 # existing rollups-node checkout, else cloned
# An immutable commit, not a branch: PR #798 (feature/contracts-bump) as
# reviewed. Override with a branch name only when you want moving code.
: "${PRT_NODE_REF:=0baf78f41c35c7280c4c0917c0794bbcd2611ad5}"
: "${PRT_DAVE_REF:=79874c0a1b40678465daf533acc976c88301c6d4}"   # == tag v3.0.0-alpha.5
: "${PRT_BIND:=127.0.0.1}"             # host interface for published ports; 0.0.0.0 to expose
: "${PRT_ANVIL_PORT:=8545}"
: "${PRT_PG_PORT:=5432}"
: "${PRT_NODE_PORT_BASE:=10000}"
: "${PRT_ANVIL_MEM:=4g}"
# Extra anvil flags. Leave empty for anvil's own history retention (dave's
# harness configuration). Something like
#   "--preserve-historical-states --max-persisted-states 8192"
# keeps more history at the cost of memory; see references/tournament-timing.md.
: "${PRT_ANVIL_EXTRA_ARGS:=}"
: "${PRT_APP_NAME:=prt-echo}"
: "${PRT_STAGING_PERIOD:=30}"
: "${PRT_FF:=4}"
: "${PRT_SLEEP_SECONDS:=2}"
: "${PRT_SNAPSHOT_GAP:=2}"
: "${PRT_MAX_ROUNDS:=5000}"
: "${PRT_ORACLE_KEEP:=current}"
: "${PRT_MNEMONIC:=test test test test test test test test test test test junk}"
# Kernel + rootfs for the built-in echo application (rollups-node's own pins).
: "${PRT_KERNEL_URL:=https://github.com/cartesi/machine-linux-image/releases/download/v0.21.0/linux-6.5.13-ctsi-2-v0.21.0.bin}"
: "${PRT_KERNEL_SHA256:=5c900060da2db2bfa84cd39cd9cd722988c83c42225f3cac55f2d3157e48f32f}"
: "${PRT_ROOTFS_URL:=https://github.com/cartesi/machine-guest-tools/releases/download/v0.18.0/rootfs-tools.ext2}"
: "${PRT_ROOTFS_SHA256:=6c159937485c99f695021c4f2ea2a57bdadcf4e4bce8e71af5bee3bb9552802e}"
: "${PRT_MIN_DISK_GB:=10}"

export PRT_WORKSPACE PRT_PROJECT PRT_SYBIL_IMAGE PRT_SLING_IMAGE PRT_NODE_IMAGE PRT_BIND \
       PRT_ANVIL_PORT PRT_PG_PORT PRT_NODE_PORT_BASE PRT_ANVIL_MEM PRT_ANVIL_EXTRA_ARGS PRT_MNEMONIC
export PRT_NODE_JSONRPC_PORT=$((PRT_NODE_PORT_BASE + 11))
export PRT_NODE_INSPECT_PORT=$((PRT_NODE_PORT_BASE + 12))
export PRT_DUMP_DIR="$PRT_WORKSPACE/dump-${PRT_DAVE_VERSION}"
export PRT_APPS_DIR="$PRT_WORKSPACE/apps"
export PRT_STATE_DIR="$PRT_WORKSPACE/state"
export PRT_ORACLE_DIR="$PRT_WORKSPACE/oracle"
export PRT_LOG_DIR="$PRT_WORKSPACE/logs"
export PRT_BUILD_DIR="$PRT_WORKSPACE/build"
NET="${PRT_PROJECT}_default"
# shellcheck disable=SC2034  # used by prt-stack.sh
DC=(docker compose -p "$PRT_PROJECT" -f "$SKILL_SCRIPTS/compose.yaml")

say()  { printf '%s\n' "$*"; }
die()  { printf 'prt-stack: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing host tool: $1"; }
# Portability notes: everything here must run on macOS bash 3.2 + BSD
# userland as well as GNU/Linux. No `sed -i`, `readlink -f`, `date -d`,
# `xargs -r`, `grep --line-buffered`, `\s` in sed, mapfile, or `${var,,}`.
# macOS has shasum, most Linux has sha256sum.
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
arg_uint() { is_uint "${2:-}" || die "$1 must be a non-negative integer, got '${2:-}'"; }

# The workspace is recursively deleted by `down`; refuse anything that could
# be a real directory of the user's. Resolved so `..` tricks do not pass.
guard_workspace() {
  local w; w="$(cd "$PRT_WORKSPACE" 2>/dev/null && pwd -P)" || die "workspace does not exist: $PRT_WORKSPACE"
  case "$w" in
    ""|/|"$HOME"|/home|/Users|/tmp|/var|/usr|/etc|/root) die "refusing to operate on workspace '$w'" ;;
  esac
  [ "$w" = "$(cd "$SKILL_SCRIPTS/.." && pwd -P)" ] && die "workspace must not be the skill directory"
  if git -C "$w" rev-parse --show-toplevel >/dev/null 2>&1; then
    [ "$(git -C "$w" rev-parse --show-toplevel)" = "$w" ] && die "workspace must not be a git repository root: $w"
  fi
  [ -f "$w/.prt-stack-workspace" ] || die "not a prt-stack workspace (no .prt-stack-workspace marker): $w"
  return 0
}

mkdir -p "$PRT_WORKSPACE" "$PRT_APPS_DIR" "$PRT_STATE_DIR" "$PRT_ORACLE_DIR" "$PRT_LOG_DIR" "$PRT_BUILD_DIR"
[ -f "$PRT_WORKSPACE/.prt-stack-workspace" ] || printf 'managed by prt-stack; safe to delete\n' > "$PRT_WORKSPACE/.prt-stack-workspace"

# One mutating command per workspace at a time (mining, metadata and nonces
# would otherwise race). mkdir is atomic on every platform we care about.
lock_workspace() {
  local d="$PRT_WORKSPACE/.lock"
  if ! mkdir "$d" 2>/dev/null; then
    local pid; pid="$(cat "$d/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      die "another prt-stack command (pid $pid) is running in $PRT_WORKSPACE"
    fi
    rm -rf "$d"; mkdir "$d" || die "cannot take workspace lock $d"
  fi
  printf '%s\n' "$$" > "$d/pid"
  trap 'rm -rf "$PRT_WORKSPACE/.lock"' EXIT
}

# Run cast/anvil/jq/curl from the sybil image on the stack network, so the
# host needs none of them. RPC inside the network is always http://anvil:8545.
tool() { docker run --rm --network "$NET" --entrypoint "$1" "$PRT_SYBIL_IMAGE" "${@:2}"; }
cast_() { tool cast "$@" --rpc-url http://anvil:8545; }
rpc()   { tool cast rpc -r http://anvil:8545 "$@"; }
mine_blocks() { rpc anvil_mine "$(printf '0x%x' "$1")" >/dev/null; }
node_rpc() { # node_rpc <method> [params-json]
  local params="${2-}"; [ -n "$params" ] || params='{}'
  tool curl -sf -X POST "http://node:10011/rpc" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$params}"
}
# Tiny JSON field extractor for the shapes the node returns (flat string values).
json_field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }

# ---- release assets ---------------------------------------------------------
verify_sha256() { # verify_sha256 <file> <expected> <what>
  [ -z "$2" ] && return 0
  local got; got="$(sha256_of "$1")"
  [ "$got" = "$2" ] || die "$3 checksum mismatch: $1 is $got, expected $2"
}

fetch_verified() { # fetch_verified <url> <dest> <sha256> <what>
  if [ ! -f "$2" ]; then
    need curl; say "fetching $4"
    curl -fsSL -o "$2.part" "$1" && mv "$2.part" "$2"
  fi
  verify_sha256 "$2" "$3" "$4"
}

# The tarball stays beside the extracted dump and is re-verified on every
# command that uses the dump, so a tampered or half-extracted cache is caught.
fetch_dump() {
  local tar="$PRT_WORKSPACE/cartesi-rollups-prt-${PRT_DAVE_VERSION}-anvil-${PRT_FOUNDRY_VERSION}.tar.gz"
  fetch_verified "https://github.com/cartesi/dave/releases/download/v${PRT_DAVE_VERSION}/$(basename "$tar")" \
    "$tar" "$PRT_DUMP_SHA256" "dave ${PRT_DAVE_VERSION} devnet dump"
  if [ ! -f "$PRT_DUMP_DIR/.verified" ] || [ "$(cat "$PRT_DUMP_DIR/.verified")" != "$(sha256_of "$tar")" ]; then
    rm -rf "$PRT_DUMP_DIR"; mkdir -p "$PRT_DUMP_DIR"; tar -xzf "$tar" -C "$PRT_DUMP_DIR"
    [ -f "$PRT_DUMP_DIR/state.json" ] || die "dump has no state.json"
    sha256_of "$tar" > "$PRT_DUMP_DIR/.verified"
  fi
}

# Deployment address by contract name, from the dump's records.
addr() {
  local f="$PRT_DUMP_DIR/deployments/31337/$1.json"
  [ -f "$f" ] || die "no deployment record for $1 in $PRT_DUMP_DIR"
  sed -n 's/.*"address": *"\(0x[0-9a-fA-F]\{40\}\)".*/\1/p' "$f" | head -1
}

# Assign, then export: `export X="$(f)"` would swallow a failing lookup
# (the die inside the substitution only ends the subshell).
export_addresses() {
  PRT_ADDR_INPUT_BOX="$(addr InputBox)"
  PRT_ADDR_APPLICATION_FACTORY="$(addr ApplicationFactory)"
  PRT_ADDR_AUTHORITY_FACTORY="$(addr AuthorityFactory)"
  PRT_ADDR_QUORUM_FACTORY="$(addr QuorumFactory)"
  PRT_ADDR_SELF_HOSTED_APPLICATION_FACTORY="$(addr SelfHostedApplicationFactory)"
  PRT_ADDR_DAVE_APP_FACTORY="$(addr DaveAppFactory)"
  PRT_ADDR_WITHDRAWAL_OUTPUT_BUILDER="$(addr TestUsdWithdrawalOutputBuilder)"
  PRT_ADDR_TOURNAMENT_PARAMETERS="$(addr CanonicalTournamentParametersProvider)"
  export PRT_ADDR_INPUT_BOX PRT_ADDR_APPLICATION_FACTORY PRT_ADDR_AUTHORITY_FACTORY PRT_ADDR_QUORUM_FACTORY \
         PRT_ADDR_SELF_HOSTED_APPLICATION_FACTORY PRT_ADDR_DAVE_APP_FACTORY PRT_ADDR_WITHDRAWAL_OUTPUT_BUILDER \
         PRT_ADDR_TOURNAMENT_PARAMETERS
}

# ---- keys ------------------------------------------------------------------
# Signer roles by anvil account index (harness index = account + 1):
#   0 deployer/claimer   6 reference node's PRT slot (idle, passive)
#   7.. honest sling nodes   after them: sybils
# Anvil funds only accounts 0-9, so anything above is funded on demand. The
# sybil driver signs from dave's bundled 40-entry key table, so accounts stop
# at 39: N_SLING + N_SYBILS <= 33.
MAX_ACCOUNT=39
# Parse by shape, not by label: a 64-hex word is the key, a 40-hex word the
# address (\b keeps the key's first 40 chars from matching as an address).
key_for()  { tool cast wallet derive-private-key "$PRT_MNEMONIC" "$1" | grep -oE '0x[0-9a-fA-F]{64}' | head -1; }
# Foundry 1.5.x prints only the key here, so derive the address from it.
addr_for() { tool cast wallet address --private-key "$(key_for "$1")" | grep -oE '0x[0-9a-fA-F]{40}' | head -1; }
fund()     { rpc anvil_setBalance "$1" 0x21E19E0C9BAB2400000 >/dev/null; }   # 10000 ETH

sling_account() { echo $((7 + $1 - 1)); }          # sling i -> account 7+i-1
sybil_first_account() { echo $((7 + $1)); }        # after N slings
check_account_budget() { # check_account_budget <n_sling> <n_sybils>
  local last=$((7 + $1 + $2 - 1))
  [ "$last" -le "$MAX_ACCOUNT" ] || die "N_SLING + N_SYBILS = $(( $1 + $2 )) exceeds the 33 signer accounts available (accounts 7..$MAX_ACCOUNT)"
}

# ---- chain reads -----------------------------------------------------------
app_address() { cat "$PRT_WORKSPACE/.app-address" 2>/dev/null || die "no app deployed yet (run: prt-stack.sh deploy)"; }
consensus_of() { cast_ call "$1" "getOutputsMerkleRootValidator()(address)"; }
# "<epoch> <lower> <upper> <tournament>" of the consensus's current sealed epoch.
sealed_epoch() { cast_ call "$1" "getCurrentSealedEpoch()(uint256,uint256,uint256,address,bool,uint256,bytes32,bytes32)" | sed -n '1,4p' | paste -sd' ' -; }
template_hash_of() { cast_ call "$1" "getTemplateHash()(bytes32)"; }
tournament_parameters() { cast_ call "$PRT_ADDR_TOURNAMENT_PARAMETERS" "tournamentParameters(uint64)(uint64,uint64,uint64,uint64,uint64)" 0 | paste -sd' ' -; }

wait_for() { # wait_for <seconds> <description> <command...>
  local t="$1" what="$2"; shift 2
  local i=0
  until "$@" >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -ge "$t" ] && die "timed out waiting for $what"
    sleep 1
  done
}

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# Root hash of a stored machine, computed by the emulator that the nodes run.
stored_hash() { # stored_hash <host machine dir>
  docker run --rm -v "$1:/m:ro" --entrypoint cartesi-machine-stored-hash "$PRT_SYBIL_IMAGE" /m 2>/dev/null \
    | grep -oE '0x[0-9a-fA-F]{64}' | tail -1
}

image_revision() { docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1" 2>/dev/null | grep -v '<no value>' || true; }

# Sybil image build context lives in the workspace (the skill dir may be
# read-only or shared); assembled from a dave checkout at PRT_DAVE_REF.
build_sybil_image() {
  local ctx="$PRT_BUILD_DIR/sybil"
  local dave="${PRT_DAVE_REPO:-$PRT_WORKSPACE/dave}"
  if [ -z "$PRT_DAVE_REPO" ]; then
    if [ ! -d "$dave/.git" ]; then
      say "cloning cartesi/dave (blobless) into $dave"
      git clone -q --filter=blob:none --no-checkout https://github.com/cartesi/dave "$dave"
    fi
    git -C "$dave" cat-file -e "$PRT_DAVE_REF^{commit}" 2>/dev/null || git -C "$dave" fetch -q origin "$PRT_DAVE_REF"
  fi
  # `git archive` of the exact commit: an existing checkout's working-tree
  # edits never leak into the image, and the revision is what we say it is.
  local rev; rev="$(git -C "$dave" rev-parse --verify "$PRT_DAVE_REF^{commit}")" \
    || die "dave ref $PRT_DAVE_REF not found in $dave"
  rm -rf "$ctx"; mkdir -p "$ctx"
  git -C "$dave" archive --format=tar "$rev" prt/client-lua test/e2e/support test/e2e/rollups/dave \
    | tar -xf - -C "$ctx"
  cp "$SKILL_SCRIPTS/sybil/Dockerfile" "$SKILL_SCRIPTS/sybil/sybils.lua" "$ctx/"
  printf '%s\n' "$rev" > "$ctx/DAVE_REV"
  docker build -q -t "$PRT_SYBIL_IMAGE" \
    --label "org.opencontainers.image.revision=$rev" \
    --label "io.cartesi.prt-stack.foundry=$PRT_FOUNDRY_VERSION" "$ctx" >/dev/null
  rm -rf "$ctx"
  say "built $PRT_SYBIL_IMAGE (dave Lua client @ ${rev:0:12})"
}
