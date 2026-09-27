# Troubleshooting

Failures actually hit while building this, and how they present. Run
`prt-stack.sh doctor` first; it catches the host-side ones.

**`mounts denied: the path ... is not shared from the host` (Docker Desktop).**
Docker Desktop only bind-mounts paths under its File Sharing list (your home
directory by default). `PRT_WORKSPACE` defaults to `$PWD/prt-stack-workspace`,
so run from somewhere under your home - not `/tmp` - or add the path in
Docker Desktop → Settings → Resources → File Sharing. The same applies to the
directory you pass to `deploy --app`.

**`port is already allocated` on 8545.** Another anvil (often a long-lived
mainnet fork) owns it. Set `PRT_ANVIL_PORT=8645` (and other ports as needed);
inside the network the chain is still `anvil:8545`. `doctor` lists the ports.

**Reference node logs `BlockOutOfRangeError: block height is H but requested
was B`, over and over; `dispute` fails with "anvil dropped history the node
needed".** The node reads the sealed epoch at the block of an `EpochSealed`
event that anvil no longer has a state for. This happens when something
mines continuously (an interval miner, a loop of `mine`) while the node is
behind, or when retention was capped too low via `PRT_ANVIL_EXTRA_ARGS`. The
node never recovers on its own: it retries the same block forever. Recovery
is `down` + `up` + `deploy` + `sling`. See `references/tournament-timing.md`,
"The mining model".

**anvil container `Exited (137)`, `OOMKilled=true`.** Only possible with
`--preserve-historical-states` in `PRT_ANVIL_EXTRA_ARGS` and a lot of mined
blocks; the container is capped at `PRT_ANVIL_MEM` so the host survives.
Lower the persisted-states count or raise the cap. Recovery is a full reset
(`down`, `up`, ...): the chain reloads from the dump.

**`deploy` fails with "could not load ... as a stored machine".** The
directory is not a `cartesi-machine --store` output, or it was stored by an
emulator other than 0.21. Rebuild the template with the node image's
`cartesi-machine` (see SKILL.md). "missing machine file referenced by
config.json" means a partial copy.

**`deploy` fails with "on-chain template hash ... differs from the staged
machine's".** The CLI deployed a different hash than the emulator computed
for the staged directory. Should not happen; if it does, the node image and
the sybil image run different emulator versions - rebuild both (`PRT_REBUILD=1
build`).

**sling node exits at boot with an initial-hash mismatch.** You deployed one
machine and pointed the node at another (`.app-machine` edited by hand?), or
the state dir belongs to a previous deployment: `WIPE=1 prt-stack.sh sling N`.
`sling` prints the node's log tail when this happens.

**sling node exits with `engine database configuration mismatch` (stored app
X, given app Y).** The state dir belongs to a previous deployment. `sling`
now records the app in `state/sling-i/.app` and clears a dir bound to another
app by itself, and `up` clears everything when it sees a recreated anvil
container (a docker prune or daemon restart destroys the chain without
`down`). If you hit it anyway: `WIPE=1 prt-stack.sh sling N`.

**sling node refuses the state dir after a release bump.** Schema changed
(alpha.4 → alpha.5 did). `WIPE=1 prt-stack.sh sling N`.

**sybils fail with "oracle lineage diverged at epoch N".** The oracle's
snapshot for epoch N does not hash to what `EpochSealed(N)` says the epoch
started from. Either the template differs from what was deployed (emulator
version), or `oracle/<app>/` was copied in from another chain. `down` clears
the oracle; if you only want to reset it, delete `oracle/<app>/`.

**sybils fail with "oracle is already at epoch X and ORACLE_KEEP=current
dropped epoch T's snapshot".** You asked `sybils --epoch T` for an epoch
older than the last one attacked, and only the newest snapshot is kept. Use
`PRT_ORACLE_KEEP=all` from the start, or delete `oracle/<app>/` to replay from
the template.

**`dispute` fails with "input N fell into an epoch that already settled".**
Something else sealed epochs between the send and the poll (a second driver
against the same app, or manual mining). One mutating command per workspace;
do not `mine` while `dispute` runs.

**`missing InputAdded for input N`.** The InputBox events for this app do
not cover the epoch's input range. Fixed cause in the bundled driver:
`InputAdded` topics arrive as 32-byte words, so the app address is zero-padded
and must be compared on its trailing 40 hex chars. If it appears again, the
`APP` address passed to the driver is wrong.

**sybils exit immediately with a Lua error.** Run with the container attached
(`sybils` already is) and read the traceback; the most common cause is the
template mount (`/machine`) pointing at a directory without `config.json`.

**A sybil appears to win** (`FAIL winner is the honest commitment`). Almost
always mining cadence: something mined a large chunk while the honest node
was on turn. Check nothing else is calling `anvil_mine` against the chain
during a dispute, and keep `PRT_FF` small.

**`FAIL silent sybil K eliminated by timeout`** but everything else passed.
The silent match was resolved some other way (for instance the honest node
won the root before the silent match expired and the tournament was
finalized with the match still pending). Look at the `match deleted` lines in
the report: the deletion naming the silent root tells you what happened.

**`epoch containing input N never sealed`.** The honest node is not settling.
Check `docker logs <project>-sling-1` for `stage tournament result` /
`settle epoch`; if it is stuck on an earlier epoch, its bond recovery may be
waiting on a finalized view - `mine 10` and retry. Make sure the reference
node is passive (otherwise it settled first and the sling node is idling).

**"another prt-stack command (pid P) is running".** The workspace lock. If
the pid is dead the lock is taken over automatically; if it is alive, wait.

**Two stacks fight each other.** Same `PRT_PROJECT` or overlapping ports.
Change both.

**Killing processes by name.** Do not `pkill -f` / `pgrep -f` the sling binary
name from a script: the pattern matches the calling shell's own command line
and kills it (exit 144). This stack addresses containers by name instead.

**`getDataAvailability()` reverts.** rollups-contracts 3.0.0-alpha.10 removed
it (use `getInputBox()`). Tooling pinned to alpha.6 or earlier - the sequencer
at the time of writing - cannot attach to apps deployed by this stack.
