# Topology

## Containers

| container | image | role |
|---|---|---|
| `<project>-anvil-1` | `prt-sybil` (entrypoint `anvil`) | the chain, loaded from the dave release dump: rollups-contracts + PRT contracts + `DaveAppFactory`, all pre-deployed. Automine only; no interval miner |
| `<project>-database-1` | `postgres` (digest-pinned) | reference node state |
| `<project>-migration-1` | node image | `cartesi-rollups-cli db init`, runs once |
| `<project>-node-1` | node image | the reference rollups-node, **passive** |
| `<project>-sling-i` | `prt-sling` | honest Dave validator *i* |
| `<project>-sybils` | `prt-sybil` | one process driving M fraudulent players; owns the oracle lineage |

Everything is on the compose project's default network. Inside it the chain is
always `http://anvil:8545`; on the host it is `http://$PRT_BIND:$PRT_ANVIL_PORT`
(loopback unless you set `PRT_BIND`).

## Workspace layout

```
$PRT_WORKSPACE/
  cartesi-rollups-prt-<ver>-anvil-<foundry>.tar.gz   release dump (verified on every use)
  dump-<ver>/                 extracted; deployments/31337/*.json are the address source
  apps/<stored hash>/         staged machine templates, content-addressed
  build/                      echo machine build, sybil image build context (transient)
  machine-images/             kernel + rootfs (checksum-pinned)
  state/sling-i/              one SQLite state dir per honest validator
  oracle/<app>/epoch-N/       oracle snapshots (machine at the START of epoch N)
  logs/sybils-<stamp>.{log,json}   every sybil run's transcript and machine-readable report
  .app-address .app-name .app-machine .n-sling .last-report   current deployment
  .lock/                      one mutating command at a time
```

`down` removes `state/`, `oracle/` and the `.app-*` files because the next
`up` reloads the dump: the chain they describe is gone. Everything else is a
cache and survives (`down --purge` clears it).

## Why the reference node is passive

The Go rollups-node has a PRT service that joins tournaments and settles, but it
never plays a match: its tournament adapter exposes `JoinTournament`,
`TryRecoveringBond`, `StageTournamentResult` and `AcceptStagedTournamentResult`
and nothing else. It is an honest uncontested claimer. Left enabled it would
compute the same commitment as the sling node, join first, and the sling node
would find its root already present and idle for good. So
`CARTESI_FEATURE_CLAIM_SUBMISSION_ENABLED=false`: the node still executes every
input, produces outputs and serves inspect/JSON-RPC - it just never signs a
tournament transaction. `dispute` uses it as an independent witness: after
settlement the epoch must be `CLAIM_ACCEPTED` in the node's database.

## Why "N honest" does not multiply anything

The sling node is honest-only by construction (no patch/corrupt/test hook
anywhere in its source). N honest nodes produce N identical commitments; the
tournament pairs distinct roots, so the first joiner takes the slot and the
rest sit in `AwaitingTournamentClosure`. `sling N` supports N>1 because it is
useful for restart, crash and redundancy tests - not because it changes the
dispute. A second node with a different machine image is refused at boot: the
local template hash must equal the on-chain initial state hash.

## Fraudulent players

A sybil is dave's Lua actor (`prt/client-lua/player`) fed a
`PatchedCommitmentBuilder`: it computes the honest commitment from the epoch's
start machine and inputs, then garbles one leaf. Sybil *k* patches
`meta_cycle = k << 44` - stride-aligned so it bites at level 0, and distinct
per sybil so they also diverge from each other (a sybil-vs-sybil pairing is
possible with M≥2, as in dave's `multi_sybil`). They play the protocol
perfectly while defending a wrong root: the strongest polite adversary. Silent
ones join and then never respond, so their matches must die by timeout.

The sybils need `cast` (transactions and reads), the `cartesi` Lua module (to
run the machine) and the same template machine as the honest node. The image
takes the emulator from the release `.deb`, which already ships the Lua module.

## The oracle lineage

Epoch 0 starts at the template. Epoch *n*+1 starts at the machine that epoch
*n*'s inputs left behind - which is why "compute the honest commitment from
the template" only works once. The sybil driver keeps an independent lineage
under `oracle/<app>/`, ported from dave's e2e `oracle_advance`:

1. `snapshot(0)` is the template; `snapshot(n)` is `epoch-n/`, a stored machine.
2. To reach the target epoch *T* it loads the highest snapshot it has, and for
   each epoch *n* below *T*: asserts the snapshot's root hash equals
   `EpochSealed(n).initialMachineStateHash`, replays epoch *n*'s chain inputs
   (`InputAdded` events, nothing from any node), stores the result as
   `epoch-(n+1)/`.
3. The honest commitment for *T* is computed from `snapshot(T)` (again checked
   against the sealed initial hash), and every sybil's `CommitmentBuilder` and
   machine path point at that snapshot.

An assertion failure names the epoch where the lineage diverged. The usual
causes: the template was built with a different emulator, or an `oracle/`
directory survived from another chain (it cannot after `down`, but can if you
copy workspaces around). `PRT_ORACLE_KEEP=all` keeps every epoch's snapshot
(each is the size of the template); the default keeps only the newest.

## Signers and state

| role | anvil account |
|---|---|
| deployer, reference node claimer | 0 |
| reference node PRT slot (idle) | 6 |
| honest sling node *i* | 7 + *i* − 1 |
| sybil *j* (after N honest) | 7 + N + *j* − 1 |

Keys are derived from anvil's default mnemonic with `cast wallet
derive-private-key`; anvil pre-funds accounts 0-9 only, so higher ones are
funded with `anvil_setBalance` before use. The sybil driver signs from dave's
bundled 40-entry key table, so N + M ≤ 33 (accounts 7..39); the driver refuses
more. A sling node's state dir is bound to its signer and to the release's
schema: change either and start it with `WIPE=1`. Each sling node needs its own
state dir - the node takes exclusive ownership and SQLite is its only
coordination.
