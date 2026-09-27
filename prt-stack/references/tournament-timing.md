# Tournament timing

## Clocks are blocks

`prt/contracts/src/tournament/libs/Time.sol`:

```solidity
function currentTime() internal view returns (Instant) {
    return Instant.wrap(uint64(block.number));
}
```

Every chess clock, allowance and deadline in PRT is denominated in blocks.
Wall-clock time is irrelevant on a local chain: you advance the tournament by
mining (`cast rpc anvil_mine N`), never by waiting.

## Where the "one week" comes from

`prt/contracts/script/Deployment.s.sol` registers a clock per chain kind and
converts seconds to blocks with the chain's nominal block time:

```solidity
_registerChainKind(ChainKind.MAINNET, Seconds.wrap(1 weeks + 1 hours));
_registerChainKind(ChainKind.TESTNET, Seconds.wrap(9 hours));
_registerChainKind(ChainKind.DEVNET,  Seconds.wrap(1 hours));   // chain 31337
// responseBudget = 5 minutes
// Duration = seconds * 1000 / avgBlockTimeMs      (31337 registered at 12000 ms)
```

So the devnet deploys with `maxAllowance = 3600/12 = 300 blocks` and
`responseBudget = 300/12 = 25 blocks`. Confirm on any chain with
`tournamentParameters(0)` on `CanonicalTournamentParametersProvider`; the
devnet returns `(3, 44, 48, 25, 300)`.

## What is safe to mine, and when

A clock burns while its owner is on turn. Mine 300 blocks in one call during a
live match and the honest node's whole allowance is gone before it wakes up.
Dave's harness notes record this reproduced: "an honest node timed out of its
own dispute at 128 blocks per idle poll".

- **No live match** (before sybils join, or after settlement): mine as hard as
  you like. `dispute` does exactly this to seal an epoch with inputs.
- **Live match**: only the driver mines - `time.sleep(1)` *then* advance a
  small chunk (`FF`, default 4), and only when every active player is idle.
  Ordering is the point: pending moves land first.
- **Timeout paths** are the exception: a silent sybil's match is *meant* to
  expire. The driver keeps fast-forwarding gently after the active players are
  done until the epoch settles.

## Going faster: two dials, one free

| dial | where | cost |
|---|---|---|
| `maxAllowance`, `responseBudget` | constructor args of `CanonicalTournamentParametersProvider`, derived from the chain-kind table | **free** - redeploy the contracts; the node asserts nothing about clocks |
| tree geometry (`LEVELS`, `log2step`, `height`) | `ArbitrationConstants` library, compile-time | **expensive** - the node refuses to boot unless `log2step == 44` and `log2step + height == 92`; changing it means recompiling contracts, regenerating bindings and rebuilding the node |

To shrink clocks, edit the DEVNET chain-kind seconds (e.g. `2 minutes` → a
10-block root allowance) and the response budget, then run the deploy scripts
against a fresh chain. Keep `responseBudget < maxAllowance` and leave the honest
node enough real time per response (it polls every `--sleep-duration-seconds`).

## The mining model

The chain runs anvil with **automine and no interval miner**, plus
`--slots-in-an-epoch 1` (block N-2 is "finalized"), exactly as dave's own e2e
harness starts it. Consequences:

- A transaction is its own block. Between commands the chain stands still:
  no empty epochs, no growing validator snapshots, no clocks ticking.
- Clocks move only when something mines: `dispute` mines 100-block chunks
  while no match is live, the sybil driver mines 1 block per poll while
  joining and `FF` blocks per idle poll during the dispute, and `mine N`
  is there for manual runs.
- Finality lags two blocks, so `up`, `deploy` and `sling` each mine three
  blocks at the end; otherwise a node polling the finalized view sees
  nothing new.

The reason is not only speed. The reference node evaluates
`getCurrentSealedEpoch` *at the block of each `EpochSealed` event* while it
walks epoch transitions. Anvil keeps a bounded history of states; a
one-second interval miner combined with a small `--max-persisted-states`
pushed those blocks out of range within an hour and the node looped on
`BlockOutOfRangeError` forever (the original version of this stack did
exactly that). With explicit mining the distance between an event and the
node's read of it stays small. If you need deeper history anyway, add
retention through `PRT_ANVIL_EXTRA_ARGS` (for example
`--preserve-historical-states --max-persisted-states 8192`), watch the
container's memory (`PRT_ANVIL_MEM` caps it), and rely on `dispute`, which
fails if the node logged that error during the run.

## How long a contested dispute takes here

With the devnet clocks and explicit mining: level 0 bisects ~48 times, seals, spawns
an inner tournament (height 17), which seals into a leaf tournament (height 27)
ending in an on-chain state-transition proof. Roughly 8-10 s per round when the
sybil answers promptly; the sybil also has to build a 2^17-leaf commitment for
the leaf level, which is the single longest step. Expect 10-20 minutes for a
full run, most of it in the deepest level.
