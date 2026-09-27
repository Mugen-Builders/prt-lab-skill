---
name: prt-stack
description: Spin up a complete local Cartesi Rollups + Dave PRT test stack and run real, contested fraud-proof tournaments against it - devnet chain from the official dave release dump, a passive reference rollups-node, N honest Dave validators ("sling nodes"), and M fraudulent players (K silent) that defend wrong commitments so the dispute runs bisection, inner tournaments, timeouts and leaf proofs. Every result is asserted from chain events (non-zero exit on a wrong winner, a surviving sybil, or a silent match that did not time out) and written as JSON. Use this whenever someone wants to test, audit, or demo Dave/PRT locally, run multiple sling nodes, simulate fraudulent or malicious validators, sybils or adversaries, deploy their own Cartesi application under PRT consensus, run several disputes on one stack, or asks how to finish a tournament without waiting days - even if they only say "test the tournament", "dispute", "dave node", "prt node", "multiple validators", or "rollups devnet". Docker-only.
---

# prt-stack

A reproducible, Docker-only stack for exercising Dave's PRT tournament with real
adversaries. It exists because three facts make ad-hoc testing misleading:

1. **The Rust sling node is honest-only by construction.** It has no flag or test
   hook to produce a wrong commitment. Two honest nodes compute the *same*
   commitment, and a tournament holds one slot per distinct commitment - so a
   second honest node never joins; it idles. Running "more sling nodes" cannot
   produce a dispute. Fraudulent players here are dave's own Lua dispute client
   with a `PatchedCommitmentBuilder`, the same actor its e2e suite uses.
2. **Tournament clocks are block-denominated** (`block.number`), and the devnet
   chain kind is a 300-block root allowance, not the mainnet week. You never
   wait; you mine - but mining in bulk during a live match burns the honest
   node's own clock and it loses on time. The chain here automines transactions
   and produces *no* other blocks: the driver mines clocks explicitly, with the
   cadence dave's harness uses (sleep first, then a small advance).
3. **An epoch does not start at the template.** Epoch 0 does; every later
   epoch starts at the machine the previous epoch's inputs left behind. The
   fraudulent players therefore keep an *oracle lineage*: replayed from chain
   inputs alone, one stored machine per epoch, each checked against the
   `EpochSealed` initial-state hash before use. That is what lets you run a
   second, third, tenth dispute on the same stack.

## What you need on the host

`bash`, `docker` with compose v2, `curl`, `git`, plus ordinary POSIX utilities
(`tar`, `sed`, `awk`, `od`). `cast`, `anvil`, `jq`, the Cartesi Machine emulator
and the Lua client all run inside images the skill builds. About 10 GiB free
disk (template 0.4 GiB, kernel+rootfs 0.4 GiB, roughly 1 GiB of validator
state per contested epoch) and 8 GiB RAM. Works on amd64 and arm64. Run
`doctor` first; it checks all of this.

## Quickstart

```bash
S=<path-to-this-skill>/scripts
$S/prt-stack.sh doctor         # tools, ports, disk, images, pins
$S/prt-stack.sh build          # fetch the dave release dump, build 3 images (first time: ~10 min, node image dominates)
$S/prt-stack.sh all 1 2 1      # up + deploy echo app + 1 honest node + dispute with 2 sybils, 1 silent
$S/prt-stack.sh dispute 1      # another contested epoch on the same stack
```

`all N M K` = `up`, `deploy`, `sling N`, `dispute M K`. Each is also a command
on its own; use them separately when deploying your own application. The exit
status is the verdict: zero only if every check below passed.

A dispute run ends with a report like:

```
=== tournament 0xAE36…4955 (epoch 1) ===
has winner         true
winner commitment  0x7498…87d8
honest commitment  0x7498…87d8
honest won         true
match deleted      reason=child_tournament winner=one
match deleted      reason=timeout winner=one
sybil 1            active eliminated=true
sybil 2            silent eliminated=true (timeout)

PASS  honest commitment joined the root tournament
PASS  sybil 1 joined with its own root
PASS  sybil 2 joined with its own root
PASS  epoch 1 settled (epoch 2 sealed)
PASS  root tournament finished with a winner
PASS  winner is the honest commitment
PASS  sybil 1 eliminated on chain (MatchDeleted, not the winner)
PASS  active sybil 1's actor reported the loss
PASS  sybil 2 eliminated on chain (MatchDeleted, not the winner)
PASS  silent sybil 2 eliminated by timeout
PASS  at least one root match ended by timeout
RESULT         PASS
reference node: epoch 1 status CLAIM_ACCEPTED; BlockOutOfRangeError since dispute start: 0
dispute 1: PASS
```

Every line is derived from chain events (`MatchDeleted`, `CommitmentJoined`,
`tournamentStanding`) - not from what a player *believes* happened - and the
same facts are in `logs/sybils-<stamp>.json` for scripts. The `dispute`
command additionally requires the reference node to have the epoch as
`CLAIM_ACCEPTED` without any `BlockOutOfRangeError`, and prints the honest
node's own `settle epoch N` / `epoch N complete: settlement and bonds finalized`
lines.

## Commands

| command | what it does |
|---|---|
| `doctor` | Preflight: host tools, docker/compose, free disk and RAM, port availability, dump checksum, image presence and source revisions; with the stack up, chain id, tournament parameters `(3, 44, 48, 25, 300)`, node JSON-RPC, and that the deployed app's on-chain template hash equals the staged machine. |
| `build` | Fetch `cartesi-rollups-prt-<ver>-anvil-<foundry>.tar.gz` (SHA-256 pinned, re-verified on every command), build `prt-sling` (release binary, checksum-pinned on amd64 and arm64), `prt-sybil` (Lua client from `git archive` of the pinned dave commit + emulator .deb + cast), and the reference-node image from `rollups-node` at `PRT_NODE_REF` (an immutable commit by default). Images carry `org.opencontainers.image.revision`; set `PRT_NODE_IMAGE` to reuse one you already have - `doctor` will tell you if it cannot verify its revision. |
| `up` | anvil (loads the dump; automine, no interval mining), Postgres, DB migration, passive reference node; waits for the node's JSON-RPC to answer. Contract addresses are read from the dump's `deployments/31337/*.json`, never hardcoded. |
| `deploy [--app DIR]` | Stage the machine under `apps/<stored hash>` (computed by the nodes' emulator, so a stale copy with the same name can never be reused and an incompatible template fails here, not at validator boot), deploy through `DaveAppFactory`, register with the node, and check `getTemplateHash()` on chain equals the staged hash. Without `--app` it builds the echo application. `--staging N` sets the claim-staging period (blocks); `--sentries a,b --sentry-manager m` configure sentries. |
| `sling N` | N honest validators, each a container with its own state dir and its own signer (anvil accounts 7, 8, …; accounts ≥10 are funded on demand). Waits for each node's `Running with config` marker and that it is still running afterwards; otherwise prints its log tail and fails. `WIPE=1` clears state dirs first. |
| `sybils M [K] [--epoch E]` | M fraudulent players against sealed epoch E (default: latest), K of them silent. Brings the oracle lineage up to E first. Runs attached, prints and asserts the report. |
| `dispute M [K]` | Records the sealed epoch, sends an input, parses its index, mines until the epoch containing *that* index is sealed, runs `sybils M K --epoch <it>`, waits for the honest node's `epoch N complete` line and for the reference node to accept the epoch. This is the one to use: a dispute over an empty epoch proves little. |
| `mine N` | Advance the chain N blocks (nothing else ever mines between commands). |
| `status` | Containers, app, sealed epoch, oracle snapshots, last report. |
| `down [--purge]` | Tear down. The stack is **ephemeral**: the chain reloads the release dump on every `up`, so `down` also removes validator state, oracle snapshots and app metadata (they describe a chain that no longer exists). Kept: dump, images, staged apps, logs; `--purge` removes those too. |

All ports and names are environment variables (`PRT_ANVIL_PORT`, `PRT_PG_PORT`,
`PRT_NODE_PORT_BASE`, `PRT_PROJECT`, `PRT_WORKSPACE`, …). Use them to run two
stacks side by side or when 8545 is taken. Published ports bind to
`127.0.0.1`; set `PRT_BIND=0.0.0.0` to expose the chain (public test mnemonic)
and database (fixed password) deliberately. Full list at the top of `lib.sh`.
One mutating command runs per workspace at a time (a lock refuses a second).

## Deploying your own application

`--app DIR` takes a **stored Cartesi machine directory** (the output of
`cartesi-machine --store`, containing `config.json` and the `*.bin` ranges). It
must be built with the same emulator the nodes run (0.21). `deploy` loads it
with that emulator to compute its root: a machine from another emulator
version fails here with a clear message instead of at every validator's boot.
To build with the right emulator without installing anything, run
`cartesi-machine` from the node image:

```bash
docker run --rm -u "$(id -u):$(id -g)" \
  -v <kernel+rootfs dir>:/usr/share/cartesi-machine/images:ro -v "$PWD/out:/out" \
  --entrypoint cartesi-machine prt-node:local \
  --ram-length=128Mi --store=/out/my-app --final-hash -- <your entrypoint command>
```

The skill fetches a checksum-pinned kernel + rootfs pair into
`$PRT_WORKSPACE/machine-images` on first use; point the mount there. The sybils
and every sling node mount the same staged template read-only - they need
byte-identical machines to reproduce the honest commitment before corrupting
it.

## Roles and signers

| role | signer | why it matters |
|---|---|---|
| deployer / node claimer | account 0 | the reference node's own claim slot stays idle |
| reference node PRT slot | account 6 | also idle - the node is passive |
| honest sling node *i* | account 7 + *i* − 1 | one state dir per signer; a state dir is bound to one key |
| sybil *j* | account 7 + N + *j* − 1 | funded on demand above account 9; N + M ≤ 33 (dave's key table has 40 entries) |

The reference node runs with `CARTESI_FEATURE_CLAIM_SUBMISSION_ENABLED=false`.
It executes inputs and serves the JSON-RPC (`POST :10011/rpc`) and inspect
(`POST :10012/inspect/<app>`) APIs, but never joins a tournament - the sling
nodes are the validators. If it submitted too, it would take the slot first and
the sling nodes would idle.

## Things that will otherwise cost you an afternoon

- **Upgrading the dave release** (`PRT_DAVE_VERSION`): the node's DB schema can
  change between alphas; a newer binary refuses an older state dir. Restart
  sling nodes with `WIPE=1`. Contracts may or may not change - compare the two
  dumps' `deployments/31337` addresses; identical CREATE2 addresses mean
  identical contracts (alpha.4 → alpha.5 was node-only).
- **Mining cadence.** `dispute` mines hard only *before* the sybils join. Once
  a match is live, only the driver mines, in small steps (`PRT_FF`, default 4)
  after letting pending moves land. If a sybil ever appears to *win*, suspect
  the cadence before suspecting the node. Nothing mines between commands.
- **Anvil history.** The reference node evaluates `getCurrentSealedEpoch` *at
  the block of each `EpochSealed` event*. With interval mining and a capped
  state history that block gets pruned and the node loops on
  `BlockOutOfRangeError` forever; that is why this stack has no interval
  miner. If you add retention flags via `PRT_ANVIL_EXTRA_ARGS`, `dispute`
  still checks the node's log for that error.
- **Two stacks on one host** need distinct `PRT_PROJECT` *and* distinct ports.
- **Speeding up further** is a contracts redeploy, not a node change: the root
  allowance and response budget are constructor arguments derived from a
  chain-kind table in dave's deployment script. The tree geometry is not free -
  the node asserts it at boot. See `references/tournament-timing.md`.

## References

- `references/tournament-timing.md` - where the clocks come from, what is safe
  to mine and when, the mining model, the two dials and which one is free.
- `references/topology.md` - why the reference node is passive, why honest N>1
  idles, the oracle lineage, signer/state-dir rules, what each container is.
- `references/troubleshooting.md` - the failures seen while building this and
  how they present.
