#!/usr/bin/env bash
# prt-stack: a local Cartesi Rollups + Dave PRT test stack with N honest
# validators and M fraudulent players, to exercise the tournament for real.
#
#   prt-stack.sh doctor                 preflight: tools, ports, disk, images, pins
#   prt-stack.sh build                  fetch the release dump, build images
#   prt-stack.sh up                     anvil + postgres + passive reference node
#   prt-stack.sh deploy [--app DIR] [--name NAME] [--staging N]
#                       [--sentries a,b] [--sentry-manager ADDR]
#   prt-stack.sh sling N                start N honest sling nodes
#   prt-stack.sh sybils M [K] [--epoch E]
#                                       M fraudulent players, K of them silent,
#                                       against sealed epoch E (default: latest)
#   prt-stack.sh dispute M [K]          seal a fresh epoch with an input, then
#                                       sybils M K on exactly that epoch, wait
#                                       for settlement and node catch-up, report
#   prt-stack.sh all N M [K]            up + deploy + sling N + dispute M K
#   prt-stack.sh mine N                 advance the chain N blocks
#   prt-stack.sh status | down [--purge]
#
# Every knob is an environment variable; see lib.sh for the full list.
# Host needs: bash, docker (compose v2), curl, git. Everything else runs in
# containers. Exit status is non-zero whenever a claim in the output failed.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd="${1:-help}"; shift || true

# ---------------------------------------------------------------------------
# `nc -z` where available (macOS ships it); bash's /dev/tcp otherwise. A bash
# built without network redirections would report every port as free, so
# nc is preferred.
port_free() {
  if command -v nc >/dev/null 2>&1; then ! nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1
  else ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; fi
}

cmd_doctor() {
  local bad=0
  ok()   { say "  ok    $*"; }
  warn() { say "  warn  $*"; }
  fail() { say "  FAIL  $*"; bad=1; }
  say "host"
  for t in bash docker curl git tar sed awk od; do command -v "$t" >/dev/null 2>&1 && ok "$t" || fail "missing $t"; done
  docker info >/dev/null 2>&1 && ok "docker daemon reachable ($(docker version -f '{{.Server.Version}}' 2>/dev/null))" || fail "docker daemon not reachable"
  docker compose version >/dev/null 2>&1 && ok "docker compose v2 ($(docker compose version --short 2>/dev/null))" || fail "docker compose v2 missing"
  local free_kb; free_kb="$(df -Pk "$PRT_WORKSPACE" | awk 'NR==2{print $4}')"
  [ "$((free_kb / 1024 / 1024))" -ge "$PRT_MIN_DISK_GB" ] && ok "free disk $((free_kb / 1024 / 1024)) GiB under $PRT_WORKSPACE" \
    || fail "free disk $((free_kb / 1024 / 1024)) GiB under $PRT_WORKSPACE (< ${PRT_MIN_DISK_GB} GiB: template 0.4 GiB, kernel+rootfs 0.4 GiB, ~1 GiB validator state per contested epoch)"
  local mem_kb=""
  if [ -r /proc/meminfo ]; then mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"; elif command -v sysctl >/dev/null 2>&1; then mem_kb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))"; fi
  [ -n "$mem_kb" ] && { [ "$((mem_kb / 1024 / 1024))" -ge 8 ] && ok "RAM $((mem_kb / 1024 / 1024)) GiB" || warn "RAM $((mem_kb / 1024 / 1024)) GiB (anvil is capped at $PRT_ANVIL_MEM; 8 GiB recommended)"; }
  # Docker Desktop (macOS/Windows) runs containers in a VM with its own memory
  # budget; anvil's cap and the node must fit inside it, not inside host RAM.
  local vm_b; vm_b="$(docker info -f '{{.MemTotal}}' 2>/dev/null || echo 0)"
  if [ "${vm_b:-0}" -gt 0 ] 2>/dev/null; then
    local vm_g=$((vm_b / 1024 / 1024 / 1024))
    [ "$vm_g" -ge 6 ] && ok "docker engine memory $vm_g GiB" || warn "docker engine memory $vm_g GiB (Docker Desktop → Settings → Resources; 6 GiB or more recommended for anvil $PRT_ANVIL_MEM + node)"
  fi
  case "$(uname -s)" in Darwin) ok "macOS: bind mounts must be under a Docker Desktop shared path (home is shared by default); workspace is $PRT_WORKSPACE" ;; esac
  say "ports (bind $PRT_BIND)"
  local up=0; container_running "${PRT_PROJECT}-anvil-1" && up=1
  for p in "$PRT_ANVIL_PORT" "$PRT_PG_PORT" "$PRT_NODE_PORT_BASE" "$PRT_NODE_JSONRPC_PORT" "$PRT_NODE_INSPECT_PORT"; do
    if port_free "$p"; then ok "$p free"; elif [ "$up" = 1 ]; then ok "$p in use by this stack"; else fail "$p in use (set PRT_ANVIL_PORT / PRT_PG_PORT / PRT_NODE_PORT_BASE)"; fi
  done
  say "assets and images"
  local tar="$PRT_WORKSPACE/cartesi-rollups-prt-${PRT_DAVE_VERSION}-anvil-${PRT_FOUNDRY_VERSION}.tar.gz"
  if [ -f "$tar" ]; then
    [ "$(sha256_of "$tar")" = "$PRT_DUMP_SHA256" ] && ok "dump ${PRT_DAVE_VERSION} checksum" || fail "dump checksum mismatch: $tar"
  else warn "dump not fetched yet (build)"; fi
  for img in "$PRT_SLING_IMAGE" "$PRT_SYBIL_IMAGE" "$PRT_NODE_IMAGE"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      local rev; rev="$(image_revision "$img")"
      ok "$img present${rev:+ (revision ${rev:0:12})}"
    else warn "$img missing (build)"; fi
  done
  local nrev; nrev="$(image_revision "$PRT_NODE_IMAGE")"
  if [ -n "$nrev" ] && [ "$nrev" != "$PRT_NODE_REF" ] && [[ "$PRT_NODE_REF" =~ ^[0-9a-f]{40}$ ]]; then
    warn "$PRT_NODE_IMAGE was built from ${nrev:0:12}, PRT_NODE_REF is ${PRT_NODE_REF:0:12} (PRT_REBUILD=1 build)"
  fi
  if [ "$up" = 1 ]; then
    say "chain"
    export_addresses
    local cid; cid="$(cast_ chain-id 2>/dev/null || true)"
    [ "$cid" = "31337" ] && ok "chain id 31337, head $(cast_ block-number)" || fail "chain id '$cid'"
    local tp; tp="$(tournament_parameters 2>/dev/null || true)"
    [ "$tp" = "3 44 48 25 300" ] && ok "tournament parameters (levels, log2step, height, responseBudget, maxAllowance) = $tp" \
      || fail "unexpected tournament parameters '$tp' (the node asserts log2step 44 / height sum 92)"
    if node_rpc cartesi_getNodeInfo >/dev/null 2>&1; then ok "reference node JSON-RPC ($(node_rpc cartesi_getNodeInfo | json_field version))"; else fail "reference node JSON-RPC not answering"; fi
    if [ -f "$PRT_WORKSPACE/.app-address" ]; then
      local app; app="$(cat "$PRT_WORKSPACE/.app-address")"
      local machine; machine="$(cat "$PRT_WORKSPACE/.app-machine")"
      local onchain; onchain="$(template_hash_of "$app")"
      [ "$onchain" = "$machine" ] && ok "app $app template hash matches staged machine" || fail "app $app template hash $onchain != staged $machine"
    fi
  fi
  [ "$bad" = 0 ] && say "doctor: all checks passed" || die "doctor: fix the FAIL lines above"
}

# ---------------------------------------------------------------------------
cmd_build() {
  need docker; need curl; need git
  fetch_dump
  if docker image inspect "$PRT_SLING_IMAGE" >/dev/null 2>&1 && [ "${PRT_REBUILD:-0}" != "1" ]; then
    say "sling image $PRT_SLING_IMAGE already present"
  else
    say "building $PRT_SLING_IMAGE (dave ${PRT_DAVE_VERSION} release binary)"
    docker build -q --build-arg "DAVE_VERSION=$PRT_DAVE_VERSION" \
      --label "org.opencontainers.image.version=$PRT_DAVE_VERSION" \
      -t "$PRT_SLING_IMAGE" "$SKILL_SCRIPTS/sling" >/dev/null
  fi
  if docker image inspect "$PRT_SYBIL_IMAGE" >/dev/null 2>&1 && [ "${PRT_REBUILD:-0}" != "1" ] \
     && [ "$(image_revision "$PRT_SYBIL_IMAGE")" = "$PRT_DAVE_REF" ]; then
    say "sybil image $PRT_SYBIL_IMAGE already present (dave @ ${PRT_DAVE_REF:0:12})"
  else
    say "building $PRT_SYBIL_IMAGE (dave Lua dispute client + emulator + cast)"
    build_sybil_image
  fi

  if docker image inspect "$PRT_NODE_IMAGE" >/dev/null 2>&1 && [ "${PRT_REBUILD:-0}" != "1" ]; then
    local rev; rev="$(image_revision "$PRT_NODE_IMAGE")"
    say "node image $PRT_NODE_IMAGE already present${rev:+ (rollups-node @ ${rev:0:12})} (PRT_REBUILD=1 to rebuild)"
    [ -z "$rev" ] && say "  note: image carries no revision label; its rollups-node version cannot be verified"
  else
    local repo="${PRT_NODE_REPO:-$PRT_WORKSPACE/rollups-node}"
    if [ ! -d "$repo/.git" ]; then
      say "cloning cartesi/rollups-node into $repo"
      git clone -q https://github.com/cartesi/rollups-node "$repo"
    fi
    git -C "$repo" cat-file -e "$PRT_NODE_REF^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin "$PRT_NODE_REF"
    git -C "$repo" checkout -q --detach "$PRT_NODE_REF" 2>/dev/null || git -C "$repo" checkout -q --detach FETCH_HEAD
    local rev; rev="$(git -C "$repo" rev-parse HEAD)"
    say "building $PRT_NODE_IMAGE from rollups-node @ ${rev:0:12} ($PRT_NODE_REF) - several minutes"
    docker build -q -t "$PRT_NODE_IMAGE" --label "org.opencontainers.image.revision=$rev" "$repo" >/dev/null
  fi
  say "build complete"
}

# ---------------------------------------------------------------------------
node_ready() { node_rpc cartesi_getNodeInfo | grep -q '"chain_id"'; }

cmd_up() {
  need docker
  fetch_dump; export_addresses
  for img in "$PRT_SYBIL_IMAGE" "$PRT_NODE_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 || die "image $img missing - run: prt-stack.sh build"
  done
  "${DC[@]}" up -d
  # A recreated anvil container is a new chain (reloaded from the dump), even
  # if `down` was never run - e.g. after a docker prune or a daemon restart.
  # Validator state, oracle snapshots and app metadata describe the old one.
  local chain; chain="$(docker inspect -f '{{.Id}}' "${PRT_PROJECT}-anvil-1")"
  if [ -f "$PRT_WORKSPACE/.chain" ] && [ "$(cat "$PRT_WORKSPACE/.chain")" != "$chain" ]; then
    say "new chain instance detected: clearing validator state, oracle snapshots and app metadata from the previous one"
    rm -rf "${PRT_STATE_DIR:?}" "${PRT_ORACLE_DIR:?}" "$PRT_WORKSPACE"/.app-* "$PRT_WORKSPACE/.n-sling" "$PRT_WORKSPACE/.last-report"
    mkdir -p "$PRT_STATE_DIR" "$PRT_ORACLE_DIR"
  fi
  printf '%s\n' "$chain" > "$PRT_WORKSPACE/.chain"
  wait_for 60 "anvil" cast_ chain-id
  [ "$(cast_ chain-id)" = "31337" ] || die "chain id is not 31337"
  wait_for 120 "reference node JSON-RPC" node_ready
  # Finality lags the head by two blocks; give the node something to finalize.
  mine_blocks 3
  say "chain      http://${PRT_BIND}:${PRT_ANVIL_PORT} (chain-id 31337, from dave ${PRT_DAVE_VERSION} dump, head $(cast_ block-number), automine)"
  say "node rpc   http://${PRT_BIND}:${PRT_NODE_JSONRPC_PORT}/rpc     inspect http://${PRT_BIND}:${PRT_NODE_INSPECT_PORT}/inspect/<app>"
  say "InputBox   $PRT_ADDR_INPUT_BOX    DaveAppFactory $PRT_ADDR_DAVE_APP_FACTORY"
}

# ---------------------------------------------------------------------------
fetch_machine_assets() {
  local dir="$PRT_WORKSPACE/machine-images"; mkdir -p "$dir"
  fetch_verified "$PRT_KERNEL_URL" "$dir/linux.bin" "$PRT_KERNEL_SHA256" "kernel for the built-in echo application"
  fetch_verified "$PRT_ROOTFS_URL" "$dir/rootfs.ext2" "$PRT_ROOTFS_SHA256" "rootfs for the built-in echo application"
}

build_echo_app() { # prints the staged machine dir name (its stored hash)
  local build="$PRT_BUILD_DIR/echo-dapp"
  if [ ! -f "$build/config.json" ]; then
    fetch_machine_assets >&2
    say "building echo-dapp machine template with the node image's emulator (0.21)" >&2
    rm -rf "$build"; mkdir -p "$PRT_BUILD_DIR"
    docker run --rm -u "$(id -u):$(id -g)" \
      -v "$PRT_WORKSPACE/machine-images:/usr/share/cartesi-machine/images:ro" \
      -v "$PRT_BUILD_DIR:/out" \
      --entrypoint cartesi-machine "$PRT_NODE_IMAGE" \
      --ram-length=128Mi --store=/out/echo-dapp --final-hash \
      -- ioctl-echo-loop --vouchers=1 --delegate-call-vouchers=1 --notices=1 --reports=1 --verbose=1 \
      >/dev/null
  fi
  stage_app "$build"
}

# Stage a stored machine under apps/<stored hash>. Content-addressing by the
# root the target emulator computes means (a) a basename collision can never
# hand the nodes a stale template, (b) the value we later compare against the
# on-chain template hash is the one every container will mount.
stage_app() { # stage_app <dir>  -> prints the stored hash
  local src="$1"
  [ -f "$src/config.json" ] || die "--app must be a stored Cartesi machine directory (cartesi-machine --store), got: $src"
  local missing=0 f
  # Every backing file config.json names must exist; a partial copy would
  # fail at boot with a much less helpful message.
  while IFS= read -r f; do
    [ -f "$src/${f#./}" ] || { say "  missing machine file referenced by config.json: $f" >&2; missing=1; }
  done < <(grep -oE '"(data|dht|dpt)_filename": *"[^"]+"' "$src/config.json" | sed 's/.*: *"//; s/"$//' | sort -u)
  [ "$missing" = 0 ] || die "incomplete stored machine: $src"
  local hash; hash="$(stored_hash "$src")"
  [ -n "$hash" ] || die "the emulator (0.21) could not load $src as a stored machine; rebuild it with the node image's cartesi-machine"
  local dst="$PRT_APPS_DIR/$hash"
  if [ ! -f "$dst/config.json" ]; then
    say "staging template as $dst" >&2
    rm -rf "$dst.tmp"; cp -r "$src" "$dst.tmp" && mv "$dst.tmp" "$dst"
  fi
  printf '%s\n' "$hash"
}

cmd_deploy() {
  local app_dir="" name="$PRT_APP_NAME" staging="$PRT_STAGING_PERIOD" sentries="" manager=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app) app_dir="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --staging) arg_uint --staging "$2"; staging="$2"; shift 2 ;;
      --sentries) sentries="$2"; shift 2 ;;
      --sentry-manager) manager="$2"; shift 2 ;;
      *) die "deploy: unknown option $1" ;;
    esac
  done
  container_running "${PRT_PROJECT}-node-1" || die "stack is not up (run: prt-stack.sh up)"
  local machine
  if [ -z "$app_dir" ]; then machine="$(build_echo_app)"; else machine="$(stage_app "$(cd "$app_dir" && pwd)")"; fi
  local salt; salt="0x$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  local extra=()
  [ -n "$sentries" ] && extra+=(--sentries "$sentries")
  [ -n "$manager" ]  && extra+=(--sentry-manager "$manager")
  say "deploying $name with Dave consensus (template $machine, staging period $staging blocks)"
  local out
  out="$("${DC[@]}" exec -T node cartesi-rollups-cli deploy application "$name" "/mnt/apps/$machine" \
        --prt --claim-staging-period="$staging" --salt "$salt" ${extra[@]+"${extra[@]}"} 2>&1)" \
    || { printf '%s\n' "$out" >&2; die "deploy failed"; }
  local app; app="$(printf '%s\n' "$out" | sed -n 's/.*application address: *\(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)"
  [ -n "$app" ] || { printf '%s\n' "$out" >&2; die "could not parse application address"; }
  local onchain; onchain="$(template_hash_of "$app")"
  [ "$onchain" = "$machine" ] || die "on-chain template hash $onchain differs from the staged machine's $machine"
  printf '%s\n' "$app" > "$PRT_WORKSPACE/.app-address"
  printf '%s\n' "$name" > "$PRT_WORKSPACE/.app-name"
  printf '%s\n' "$machine" > "$PRT_WORKSPACE/.app-machine"
  rm -rf "${PRT_ORACLE_DIR:?}/${app:?}"
  mine_blocks 3
  printf '%s\n' "$out" | grep -E "application address|consensus address" | sed 's/^[[:space:]]*/  /'
  say "  template hash        $machine (on-chain getTemplateHash matches)"
}

# ---------------------------------------------------------------------------
# Returns 0 when the node is up, 2 when it refused its state dir (unusable:
# bound to another app or an older schema), 1 for any other failure.
sling_wait_ready() { # sling_wait_ready <container>
  local c="$1" i=0
  # The node prints its config once it has loaded the machine and checked the
  # template against the chain; geometry/hash/signer failures happen before.
  until docker logs "$c" 2>&1 | grep -q "Running with config"; do
    i=$((i+1))
    if ! container_running "$c" || [ "$i" -ge 90 ]; then
      docker logs "$c" 2>&1 | grep -qE "configuration mismatch|could not create .storage." && return 2
      docker logs --tail 20 "$c" 2>&1 | sed 's/^/    /' >&2
      say "sling node $c did not start (log tail above)" >&2; return 1
    fi
    sleep 1
  done
  sleep 3
  if ! container_running "$c"; then
    docker logs --tail 20 "$c" 2>&1 | sed 's/^/    /' >&2
    say "sling node $c exited right after start (log tail above)" >&2; return 1
  fi
}

start_sling() { # start_sling <container> <state dir> <key> <app> <machine>
  docker rm -f "$1" >/dev/null 2>&1 || true
  mkdir -p "$2"
  docker run -d --name "$1" --network "$NET" \
    --user "$(id -u):$(id -g)" \
    -e RUST_LOG=info,cartesi_rollups_prt_node=info \
    -v "$PRT_APPS_DIR/$5:/machine:ro" \
    -v "$2:/state" \
    "$PRT_SLING_IMAGE" \
      --app-address "$4" --machine-path /machine --state-dir /state \
      --web3-rpc-url http://anvil:8545 --web3-chain-id 31337 \
      --sleep-duration-seconds "$PRT_SLEEP_SECONDS" --snapshot-gap-inputs "$PRT_SNAPSHOT_GAP" \
      pk --web3-private-key "$3" >/dev/null
}

cmd_sling() {
  local n="${1:-1}"; arg_uint N "$n"; [ "$n" -ge 1 ] || die "sling: N must be >= 1"
  check_account_budget "$n" 0
  local app machine; app="$(app_address)"; machine="$(cat "$PRT_WORKSPACE/.app-machine")"
  for i in $(seq 1 "$n"); do
    local acct key state cname
    acct="$(sling_account "$i")"; key="$(key_for "$acct")"
    [ "$acct" -ge 10 ] && fund "$(addr_for "$acct")"
    state="$PRT_STATE_DIR/sling-$i"; cname="${PRT_PROJECT}-sling-$i"
    # A state dir is bound to one application, one signer and one release
    # schema; anything else makes the node refuse it ("engine database
    # configuration mismatch"). Such a dir is useless, so: WIPE=1 clears it
    # up front, a marker from another app clears it, and a refusal at boot
    # clears it and retries once. The marker is written only once the node
    # has accepted the dir.
    [ "${WIPE:-0}" = "1" ] && rm -rf "$state"
    if [ -f "$state/.app" ] && [ "$(cat "$state/.app")" != "$app" ]; then
      say "state $state belonged to app $(cat "$state/.app"); clearing it for $app"
      rm -rf "$state"
    fi
    start_sling "$cname" "$state" "$key" "$app" "$machine"
    local rc=0; sling_wait_ready "$cname" || rc=$?
    if [ "$rc" = 2 ]; then
      say "sling node $i refused its state dir (bound to another app or schema); clearing $state and retrying"
      rm -rf "$state"
      start_sling "$cname" "$state" "$key" "$app" "$machine"
      rc=0; sling_wait_ready "$cname" || rc=$?
    fi
    [ "$rc" = 0 ] || die "sling node $i failed to start"
    printf '%s\n' "$app" > "$state/.app"
    say "honest sling node $i: container $cname, signer account $acct, state $state"
  done
  printf '%s\n' "$n" > "$PRT_WORKSPACE/.n-sling"
  mine_blocks 3
  [ "$n" -gt 1 ] && say "note: honest nodes compute identical commitments; only one holds the tournament slot, the others idle (useful for restart/redundancy tests, not for disputes)"
  return 0
}

# ---------------------------------------------------------------------------
cmd_sybils() {
  local pos=() epoch=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --epoch) arg_uint --epoch "${2:-}"; epoch="$2"; shift 2 ;;
      -*) die "sybils: unknown option $1" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  local m="${pos[0]:-1}" k="${pos[1]:-0}"
  arg_uint M "$m"; arg_uint K "$k"
  [ "$m" -ge 1 ] || die "sybils: M must be >= 1"; [ "$k" -le "$m" ] || die "sybils: K cannot exceed M"
  local app machine n_sling first
  app="$(app_address)"; machine="$(cat "$PRT_WORKSPACE/.app-machine")"
  n_sling="$(cat "$PRT_WORKSPACE/.n-sling" 2>/dev/null || echo 1)"
  check_account_budget "$n_sling" "$m"
  first="$(sybil_first_account "$n_sling")"
  for a in $(seq "$first" $((first + m - 1))); do [ "$a" -ge 10 ] && fund "$(addr_for "$a")"; done
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local cname="${PRT_PROJECT}-sybils" log="$PRT_LOG_DIR/sybils-$stamp.log" report="$PRT_LOG_DIR/sybils-$stamp.json"
  local oracle="$PRT_ORACLE_DIR/$app"; mkdir -p "$oracle"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  say "running $m fraudulent player(s), $k silent, signers from account $first, epoch ${epoch:-latest}  (log: $log)"
  # awk instead of `grep --line-buffered`: the latter is GNU-only.
  set +e
  docker run --rm --name "$cname" --network "$NET" --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$PRT_APPS_DIR/$machine:/machine:ro" -v "$oracle:/oracle" -v "$PRT_LOG_DIR:/report" \
    -e RPC=http://anvil:8545 -e APP="$app" -e TEMPLATE_MACHINE=/machine -e ORACLE_DIR=/oracle \
    -e ORACLE_KEEP="$PRT_ORACLE_KEEP" -e EPOCH="$epoch" -e REPORT="/report/$(basename "$report")" \
    -e N_SYBILS="$m" -e N_SILENT="$k" -e FF="$PRT_FF" -e PK_INDEX=$((first + 1)) \
    -e MAX_ROUNDS="$PRT_MAX_ROUNDS" -e MINE="${PRT_MINE:-1}" \
    "$PRT_SYBIL_IMAGE" 2>&1 | awk '!/building big machine commitment/ { print; fflush() }' | tee "$log"
  local rc="${PIPESTATUS[0]}"
  set -e
  printf '%s\n' "$report" > "$PRT_WORKSPACE/.last-report"
  [ "$rc" = 0 ] || die "sybil run failed (exit $rc); report: $report"
}

# ---------------------------------------------------------------------------
node_epoch_status() { node_rpc cartesi_getEpoch "{\"application\":\"$1\",\"epoch_index\":\"$(printf '0x%x' "$2")\"}" | json_field status; }

cmd_dispute() {
  local m="${1:-1}" k="${2:-0}"
  arg_uint M "$m"; arg_uint K "$k"
  local app name; app="$(app_address)"; name="$(cat "$PRT_WORKSPACE/.app-name")"
  container_running "${PRT_PROJECT}-sling-1" || die "no honest sling node running (run: prt-stack.sh sling 1)"
  local cons; cons="$(consensus_of "$app")"
  local since; since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Record the sealed epoch BEFORE sending, then wait for the one epoch whose
  # input range contains the index the InputBox returned - never "whichever
  # epoch is current when the sybils start".
  local before; before="$(sealed_epoch "$cons" | cut -d' ' -f1)"
  say "sending an input so the next sealed epoch has something to dispute"
  local sent; sent="$("${DC[@]}" exec -T node cartesi-rollups-cli send "$name" "prt-stack dispute $(date +%s)" --yes 2>&1)" \
    || { printf '%s\n' "$sent" >&2; die "send failed"; }
  local idx; idx="$(printf '%s\n' "$sent" | sed -n 's/.*Index: *\([0-9]*\).*/\1/p' | head -1)"
  [ -n "$idx" ] || { printf '%s\n' "$sent" >&2; die "could not parse the input index"; }
  say "  input index $idx (sealed epoch was $before)"
  # The current epoch is uncontested, so mining hard here is safe: no live
  # match means no clock under pressure.
  local i=0 e lo up _
  while :; do
    read -r e lo up _ <<<"$(sealed_epoch "$cons")"
    [ "$e" -gt "$before" ] && [ "$lo" -le "$idx" ] && [ "$idx" -lt "$up" ] && break
    [ "$e" -gt "$before" ] && [ "$idx" -lt "$lo" ] && die "input $idx fell into an epoch that already settled (epoch $e is [$lo, $up))"
    i=$((i+1)); [ "$i" -gt 90 ] && die "epoch containing input $idx never sealed (is the honest node settling? docker logs ${PRT_PROJECT}-sling-1)"
    mine_blocks 100; sleep 4
  done
  say "epoch $e sealed with inputs [$lo, $up) - starting the fraudulent players against it"
  cmd_sybils "$m" "$k" --epoch "$e"
  # Settlement is not the end of the honest node's cycle: it still recovers
  # its bonds against a finalized view before logging the epoch complete.
  local j=0
  until docker logs "${PRT_PROJECT}-sling-1" 2>&1 | grep -q "epoch $e complete: settlement and bonds finalized"; do
    j=$((j+1)); [ "$j" -gt 60 ] && { say "note: epoch $e settled but bond finalization not yet logged (check docker logs ${PRT_PROJECT}-sling-1)"; break; }
    sleep 1; mine_blocks "$PRT_FF" || true; sleep 3
  done
  # The reference node must have followed: the disputed epoch accepted in its
  # database and no historical-state error while it walked the epoch events.
  local st="" t=0
  until [ "$st" = "CLAIM_ACCEPTED" ]; do
    st="$(node_epoch_status "$name" "$e" 2>/dev/null || true)"
    [ "$st" = "CLAIM_ACCEPTED" ] && break
    t=$((t+1)); [ "$t" -gt 45 ] && break
    sleep 1; mine_blocks "$PRT_FF" || true; sleep 1
  done
  local oor; oor="$(docker logs --since "$since" "${PRT_PROJECT}-node-1" 2>&1 | grep -c "BlockOutOfRangeError" || true)"
  say ""
  say "reference node: epoch $e status ${st:-unknown}; BlockOutOfRangeError since dispute start: $oor"
  say "honest node highlights:"
  # The node re-logs its standing decision every tick; collapse repeats by
  # dropping the timestamp before de-duplicating.
  docker logs "${PRT_PROJECT}-sling-1" 2>&1 \
    | grep -E "won tournament|lost|stage tournament|settle epoch|complete: settlement|timeout|eliminat" \
    | awk '{k=$0; sub(/^\[[^]]*\] /,"",k)} !seen[k]++' | tail -8 | sed 's/^/  /'
  say "report: $(cat "$PRT_WORKSPACE/.last-report")"
  [ "$st" = "CLAIM_ACCEPTED" ] || die "reference node did not reach CLAIM_ACCEPTED for epoch $e (status '${st:-unknown}')"
  [ "$oor" = 0 ] || die "reference node hit BlockOutOfRangeError $oor times: anvil dropped history the node needed (see references/troubleshooting.md)"
  say "dispute $e: PASS"
}

# ---------------------------------------------------------------------------
cmd_mine() { local n="${1:-1}"; arg_uint N "$n"; mine_blocks "$n"; say "head $(cast_ block-number)"; }

cmd_status() {
  "${DC[@]}" ps --format '  {{.Name}}  {{.State}}' 2>/dev/null || true
  docker ps --filter "name=${PRT_PROJECT}-sling-" --format '  {{.Names}}  {{.Status}}'
  docker ps --filter "name=${PRT_PROJECT}-sybils" --format '  {{.Names}}  {{.Status}}'
  if [ -f "$PRT_WORKSPACE/.app-address" ] && container_running "${PRT_PROJECT}-anvil-1"; then
    local app cons; app="$(cat "$PRT_WORKSPACE/.app-address")"; cons="$(consensus_of "$app")"
    say "  app $app  consensus $cons  template $(cat "$PRT_WORKSPACE/.app-machine")"
    read -r e lo up t <<<"$(sealed_epoch "$cons")"
    say "  sealed epoch $e  inputs [$lo, $up)  tournament $t   head $(cast_ block-number)"
    local snaps="" d
    for d in "$PRT_ORACLE_DIR/$app"/epoch-*; do [ -d "$d" ] && snaps="$snaps$(basename "$d") "; done
    say "  oracle snapshots: ${snaps:-none (template only)}"
  fi
  [ -f "$PRT_WORKSPACE/.last-report" ] && say "  last report $(cat "$PRT_WORKSPACE/.last-report")"
  return 0
}

# Ephemeral by design: the chain reloads the release dump on every `up`, so
# app metadata, validator state and oracle snapshots describe a chain that no
# longer exists. `down` removes them; `--purge` also drops the caches.
cmd_down() {
  guard_workspace
  for c in $(docker ps -aq --filter "name=${PRT_PROJECT}-sling-") $(docker ps -aq --filter "name=${PRT_PROJECT}-sybils"); do
    docker rm -f "$c" >/dev/null
  done
  "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "${PRT_STATE_DIR:?}" "${PRT_ORACLE_DIR:?}" "$PRT_WORKSPACE"/.app-* "$PRT_WORKSPACE/.n-sling" "$PRT_WORKSPACE/.last-report" "$PRT_WORKSPACE/.chain"
  if [ "${1:-}" = "--purge" ]; then
    rm -rf "$PRT_APPS_DIR" "$PRT_BUILD_DIR" "$PRT_WORKSPACE/machine-images" "$PRT_LOG_DIR"
    say "stack down; validator state, oracle, app metadata, staged apps, build caches and logs removed"
  else
    say "stack down; validator state, oracle and app metadata removed (a new chain needs a new deploy). Kept: dump, images, staged apps, logs. down --purge clears those too."
  fi
}

cmd_all() {
  local n="${1:-1}" m="${2:-1}" k="${3:-0}"
  arg_uint N "$n"; arg_uint M "$m"; arg_uint K "$k"; check_account_budget "$n" "$m"
  cmd_up; cmd_deploy; cmd_sling "$n"; cmd_dispute "$m" "$k"
}

case "$cmd" in
  doctor)  cmd_doctor "$@" ;;
  status)  cmd_status "$@" ;;
  build)   lock_workspace; cmd_build "$@" ;;
  up)      lock_workspace; cmd_up "$@" ;;
  deploy)  lock_workspace; cmd_deploy "$@" ;;
  sling)   lock_workspace; cmd_sling "$@" ;;
  sybils)  lock_workspace; cmd_sybils "$@" ;;
  dispute) lock_workspace; cmd_dispute "$@" ;;
  all)     lock_workspace; cmd_all "$@" ;;
  mine)    lock_workspace; cmd_mine "$@" ;;
  down)    lock_workspace; cmd_down "$@" ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
