# prt-lab-skill

The `prt-stack` skill: a local Dave PRT laboratory.

A Claude Code skill that spins up a complete local Cartesi Rollups + Dave PRT
test stack and runs real, contested fraud-proof tournaments against it:

- devnet chain from the official dave release dump (anvil, automine only)
- PostgreSQL + a passive reference rollups-node
- N honest Dave validators ("sling nodes", the release binary)
- M fraudulent players (K of them silent) built on dave's own Lua dispute
  client with patched commitments, so the tournament actually runs bisection,
  inner tournaments, timeouts and leaf proofs
- every outcome asserted from chain events and written as JSON; non-zero exit
  on a wrong winner, a surviving sybil, or a silent match that did not time out

Docker-only. The host needs `bash`, `docker` with compose v2, `curl` and `git`.
Linux (amd64/arm64) and macOS (Intel/Apple silicon) are supported.

## Install

Skills are directories; put `prt-stack/` where your agent looks for them.

```bash
git clone git@github.com:Mugen-Builders/prt-lab-skill.git

# for one project (recommended for team repos):
mkdir -p <your-repo>/.claude/skills
cp -R prt-lab-skill/prt-stack <your-repo>/.claude/skills/

# or for every project on your machine:
mkdir -p ~/.claude/skills
cp -R prt-lab-skill/prt-stack ~/.claude/skills/
```

A symlink instead of a copy keeps it on the repo's version:
`ln -s "$PWD/prt-lab-skill/prt-stack" ~/.claude/skills/prt-stack`.

Claude Code picks the skill up automatically when the conversation is about
testing Dave/PRT, sling nodes, disputes or fraudulent validators; you can also
just run the scripts by hand. Codex does not scan `.claude/skills`; run the
scripts directly there.

## Use

```bash
S=prt-stack/scripts
$S/prt-stack.sh doctor          # tools, docker memory, ports, disk, pins
$S/prt-stack.sh build           # dump + 3 images (first time ~10 min; node image dominates)
$S/prt-stack.sh all 1 2 1       # up, deploy echo app, 1 honest node, dispute: 2 sybils, 1 silent
$S/prt-stack.sh dispute 1       # another contested epoch on the same stack
$S/prt-stack.sh down            # ephemeral: wipes state, oracle and app metadata
```

`prt-stack/SKILL.md` is the full manual (commands, roles, your own
application, the traps). `prt-stack/references/` explains the timing model,
the topology and the failures seen so far.

## macOS notes

- Run from a directory under your home. Docker Desktop only bind-mounts paths
  in its File Sharing list, and the workspace defaults to
  `$PWD/prt-stack-workspace`.
- Give the Docker Desktop VM at least 6 GiB (Settings → Resources). anvil is
  capped at 4 GiB inside that budget. `doctor` checks it.
- Ports bind to `127.0.0.1` by default. If 8545 is taken, set
  `PRT_ANVIL_PORT` (and `PRT_PG_PORT`, `PRT_NODE_PORT_BASE`).
- Everything is pinned per architecture (emulator, foundry, the dave node
  binary, base image digests), so Apple silicon builds native images; no
  emulation.

## Layout

```
prt-stack/
  SKILL.md                 what the skill does and how to use it
  scripts/prt-stack.sh     the driver: doctor build up deploy sling sybils dispute all mine status down
  scripts/lib.sh           configuration (every knob is an env var) and helpers
  scripts/compose.yaml     anvil + postgres + passive reference node
  scripts/sling/           honest validator image (dave release binary)
  scripts/sybil/           fraudulent-player image and driver (sybils.lua)
  references/              tournament-timing, topology, troubleshooting
  evals/evals.json         test prompts and what they must prove
```

## Versions pinned

| component | pin |
|---|---|
| dave | 3.0.0-alpha.5 (dump SHA-256 and node binary SHA-256 per arch; Lua client at the tag's commit) |
| rollups-node | commit `0baf78f4` (PR #798, contracts alpha.10) built from source |
| cartesi machine emulator | 0.21.0 (.deb per arch) |
| foundry | 1.5.1 |
| kernel / rootfs | linux-6.5.13-ctsi-2 v0.21.0 / rootfs-tools v0.18.0 |

Change them through `PRT_DAVE_VERSION`, `PRT_NODE_REF` and friends in
`scripts/lib.sh`; `doctor` reports what an existing image was built from.
