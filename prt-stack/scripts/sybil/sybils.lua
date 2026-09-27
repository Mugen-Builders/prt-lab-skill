-- Fraudulent players for a live Dave tournament.
--
-- Runs N sybils against one sealed epoch of an application on an existing
-- chain (not the harness's own anvil). Each sybil defends a commitment that
-- diverges from the honest one - and from every other sybil - at a distinct
-- level-0 leaf, exactly the shape dave's multi_sybil scenario uses. The last
-- N_SILENT of them join and then go quiet, so their matches must die by a
-- real on-chain timeout.
--
-- The honest commitment comes from an ORACLE LINEAGE, not from the template:
-- epoch 0 starts at the template, and every later epoch starts at the machine
-- left by the previous epoch's inputs. The lineage is replayed from chain
-- inputs alone (never from a node's snapshots) and persisted under
-- ORACLE_DIR as one stored machine per epoch, each verified against the
-- EpochSealed initial-state hash before it is used. This is dave's e2e
-- `oracle_advance` design, ported so that any number of disputes can run on
-- one stack.
--
-- Every claim in the final report is also ASSERTED: the process exits
-- non-zero if the honest root did not win, if any sybil was not eliminated
-- on chain, or if a silent sybil's match did not die by timeout. The same
-- facts are written as JSON to REPORT for machines to read.
--
-- Env:
--   RPC               http endpoint of the chain (default http://127.0.0.1:8545)
--   APP               application address (required)
--   TEMPLATE_MACHINE  stored template machine dir (required; epoch-0 state)
--   ORACLE_DIR        where epoch snapshots live (default _oracle)
--   ORACLE_KEEP       "current" (default) keeps only the newest snapshot,
--                     "all" keeps every epoch's
--   EPOCH             sealed epoch number to attack (default: latest sealed)
--   N_SYBILS          how many fraudulent players (default 1)
--   N_SILENT          how many of them go silent after joining (default 0)
--   FF                blocks per fast-forward when everyone is idle (default 4)
--   PK_INDEX          first index into the harness account list to sign with
--                     (index = anvil account + 1; the table has 40 entries)
--   MAX_ROUNDS        dispute-loop safety cap (default 5000)
--   MINE              "1" (default) to mine one block per poll; "0" on a chain
--                     that already produces blocks
--   REPORT            path of the JSON report to write (default: none)

local Hash = require "cryptography.hash"
local Machine = require "computation.machine"
local CommitmentBuilder = require "computation.commitment"
local PatchedCommitmentBuilder = require "runners.helpers.patched_commitment"
local start_sybil = require "runners.sybil_runner"
local Reader = require "dave.reader"
local blockchain_consts = require "blockchain.constants"
local blockchain_utils = require "blockchain.utils"
local time = require "utils.time"
local uint256 = require "utils.bint" (256)

local function env(name, default)
    local v = os.getenv(name)
    if v == nil or v == "" then return default end
    return v
end

local RPC = env("RPC", "http://127.0.0.1:8545")
local APP = assert(env("APP"), "APP (application address) is required")
local TEMPLATE_MACHINE = assert(env("TEMPLATE_MACHINE"), "TEMPLATE_MACHINE is required")
local ORACLE_DIR = env("ORACLE_DIR", "_oracle")
local ORACLE_KEEP = env("ORACLE_KEEP", "current")
local EPOCH = tonumber(env("EPOCH", ""))
local N_SYBILS = tonumber(env("N_SYBILS", "1"))
local N_SILENT = tonumber(env("N_SILENT", "0"))
local FF = tonumber(env("FF", "4"))
local PK_INDEX = tonumber(env("PK_INDEX", "9"))
local MAX_ROUNDS = tonumber(env("MAX_ROUNDS", "5000"))
local MINE = env("MINE", "1") == "1"
local REPORT = env("REPORT", nil)
assert(N_SYBILS >= 1, "N_SYBILS must be >= 1")
assert(N_SILENT <= N_SYBILS, "N_SILENT cannot exceed N_SYBILS")
assert(ORACLE_KEEP == "current" or ORACLE_KEEP == "all", "ORACLE_KEEP must be current or all")

local LOG2_STRIDE, ROOT_HEIGHT = 44, 48 -- the contracts' level-0 geometry (asserted by the node at boot)

local function say(fmt, ...) io.stdout:write(string.format(fmt, ...), "\n"); io.stdout:flush() end
local function lower(s) return (tostring(s):lower()) end
local function hex(h) return h and h.hex_string and h:hex_string() or tostring(h) end
-- Event topics arrive as 32-byte words, so an address topic is zero-padded to
-- 64 hex chars. Compare on the trailing 40 hex chars, case-insensitively.
local function same_address(a, b)
    local function tail40(x) return lower(x):gsub("^0x", ""):sub(-40) end
    return tail40(a) == tail40(b)
end
local function exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end
local function sh(fmt, ...)
    local cmd = string.format(fmt, ...)
    assert(os.execute(cmd), "command failed: " .. cmd)
end

-- ---------------------------------------------------------------------------
-- Report: every fact printed at the end is also recorded here and, where it
-- is a claim, checked. `failures` decides the exit code.
-- ---------------------------------------------------------------------------
local report = { ok = false, checks = {}, sybils = {}, matches_deleted = {} }
local failures = 0
local function check(name, cond, detail)
    cond = cond and true or false
    report.checks[#report.checks + 1] = { name = name, passed = cond, detail = detail }
    if not cond then failures = failures + 1 end
    return cond
end
local function fatal(fmt, ...) error(string.format(fmt, ...), 0) end

local function json(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if math.type(v) == "integer" then return tostring(v) end
        return string.format("%.17g", v)
    end
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if t == "table" then
        if v.hex_string then return json(v:hex_string()) end
        if #v > 0 or next(v) == nil then
            local parts = {}
            for i = 1, #v do parts[i] = json(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for i, k in ipairs(keys) do parts[i] = json(k) .. ":" .. json(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json(tostring(v))
end

local function write_report()
    if not REPORT then return end
    local f = assert(io.open(REPORT, "w"))
    f:write(json(report), "\n")
    f:close()
end

-- `cast call` with a single typed return value.
local function call1(address, sig, ...)
    local args = { ... }
    local quoted = {}
    for i, a in ipairs(args) do quoted[i] = '"' .. a .. '"' end
    local cmd = string.format('cast call --rpc-url "%s" "%s" "%s" %s 2>&1',
        RPC, address, sig, table.concat(quoted, " "))
    local h = assert(io.popen(cmd))
    local out = h:read("*a"); h:close()
    assert(not out:find("Error"), "cast call failed: " .. out)
    return (out:gsub("%s+$", ""))
end

local function mine(n)
    if MINE then blockchain_utils.advance_time(n, RPC) end
end

-- Clock-safe fast-forward: let pending moves land, THEN advance. Bulk mining
-- while a match is live burns the honest node's block-denominated clock.
local function fast_forward(n)
    time.sleep(1)
    mine(n)
end

local function player_react(co)
    local ok, log = coroutine.resume(co)
    if not ok then fatal("player failed to resume: %s", tostring(log)) end
    return coroutine.status(co), log
end

local function main()
    -- -----------------------------------------------------------------------
    -- 1. Discover the consensus, the InputBox, and the sealed epochs.
    -- -----------------------------------------------------------------------
    local consensus = call1(APP, "getOutputsMerkleRootValidator()(address)")
    local input_box = call1(consensus, "getInputBox()(address)")
    report.app, report.consensus, report.input_box, report.rpc = APP, consensus, input_box, RPC
    say("app            %s", APP)
    say("consensus      %s", consensus)
    say("input box      %s", input_box)

    -- A Reader without going through Reader:new (which re-derives the app
    -- from a factory we do not want to depend on).
    local reader = setmetatable({
        input_box_address = input_box,
        consensus_address = consensus,
        endpoint = RPC,
        genesis = 0,
    }, Reader)
    do
        local InnerReader = require "player.reader"
        reader.inner_reader = InnerReader:new(RPC)
    end

    local sealed = reader:read_epochs_sealed()
    if #sealed == 0 then fatal("no EpochSealed events found for consensus %s", consensus) end
    for i, e in ipairs(sealed) do
        if e.epoch_number ~= i - 1 then fatal("EpochSealed events are not contiguous at epoch %d", i - 1) end
    end

    local epoch
    if EPOCH then
        epoch = sealed[EPOCH + 1]
        if not epoch or epoch.epoch_number ~= EPOCH then
            fatal("epoch %d is not sealed yet (latest sealed: %d)", EPOCH, sealed[#sealed].epoch_number)
        end
    else
        epoch = sealed[#sealed]
    end
    report.epoch = {
        number = epoch.epoch_number,
        input_lower_bound = epoch.input_lower_bound,
        input_upper_bound = epoch.input_upper_bound,
        tournament = epoch.tournament,
        initial_machine_state_hash = epoch.initial_machine_state_hash,
    }
    say("target epoch   %d  inputs [%d, %d)  tournament %s",
        epoch.epoch_number, epoch.input_lower_bound, epoch.input_upper_bound, epoch.tournament)

    -- -----------------------------------------------------------------------
    -- 2. Chain inputs of a sealed epoch, straight from InputAdded events.
    -- -----------------------------------------------------------------------
    local all_inputs
    local function chain_inputs(e)
        all_inputs = all_inputs or reader:read_inputs_added()
        local by_index = {}
        for _, v in ipairs(all_inputs) do
            if same_address(v.app_contract, APP) then by_index[v.index] = v.data end
        end
        local inputs = {}
        for i = e.input_lower_bound, e.input_upper_bound - 1 do
            inputs[#inputs + 1] = by_index[i] or fatal("missing InputAdded for input %d of epoch %d", i, e.epoch_number)
        end
        return inputs
    end

    -- -----------------------------------------------------------------------
    -- 3. Oracle lineage. snapshot(n) is the machine at the START of epoch n:
    --    the template for n = 0, otherwise ORACLE_DIR/epoch-n, produced by
    --    replaying epoch n-1's chain inputs into snapshot(n-1). Each snapshot
    --    is checked against EpochSealed.initialMachineStateHash before use,
    --    so a mismatch names the exact epoch where the lineage diverged.
    -- -----------------------------------------------------------------------
    local scratch = ORACLE_DIR .. "/scratch"
    sh("mkdir -p '%s' && rm -rf '%s' && mkdir -p '%s'", ORACLE_DIR, scratch, scratch)
    -- The actors' own machines store rejection snapshots under
    -- Machine.default_snapshot_scratch, relative to the working directory:
    -- point it into ORACLE_DIR (the one place guaranteed writable) and clear
    -- it, as dave's harness does at scenario start.
    Machine.default_snapshot_scratch = ORACLE_DIR .. "/actor-scratch"
    sh("rm -rf '%s'", Machine.default_snapshot_scratch)
    local function snapshot(n) return n == 0 and TEMPLATE_MACHINE or (ORACLE_DIR .. "/epoch-" .. n) end
    local function have_snapshot(n) return exists(snapshot(n) .. "/config.json") end

    local function highest_snapshot()
        local best = 0
        local h = io.popen("ls -1 '" .. ORACLE_DIR .. "' 2>/dev/null")
        if h then
            for name in h:lines() do
                local n = tonumber(name:match("^epoch%-(%d+)$"))
                if n and n > best and have_snapshot(n) then best = n end
            end
            h:close()
        end
        return best
    end

    local function load(n)
        local m = Machine:new_from_path(snapshot(n), scratch)
        local h = m:state().root_hash
        local e = sealed[n + 1]
        if not (Hash:from_digest_hex(e.initial_machine_state_hash) == h) then
            fatal("oracle lineage diverged at epoch %d: snapshot %s hashes to %s but EpochSealed says %s"
                .. " (template built with another emulator, or a stale ORACLE_DIR from a different chain?)",
                n, snapshot(n), hex(h), e.initial_machine_state_hash)
        end
        return m, h
    end

    local target = epoch.epoch_number
    local cursor = highest_snapshot()
    if cursor > target and not have_snapshot(target) then
        fatal("oracle is already at epoch %d and ORACLE_KEEP=%s dropped epoch %d's snapshot;"
            .. " use ORACLE_KEEP=all or wipe %s", cursor, ORACLE_KEEP, target, ORACLE_DIR)
    end
    if have_snapshot(target) then cursor = target end
    for n = cursor, target - 1 do
        local m = load(n)
        local inputs = chain_inputs(sealed[n + 1])
        say("oracle         replaying epoch %d (%d inputs) -> snapshot for epoch %d", n, #inputs, n + 1)
        m:rollup_commitment(LOG2_STRIDE, inputs)
        local tmp = snapshot(n + 1) .. ".tmp"
        sh("rm -rf '%s'", tmp)
        m:store_to(tmp)
        assert(os.rename(tmp, snapshot(n + 1)))
        if ORACLE_KEEP ~= "all" and n > 0 then sh("rm -rf '%s'", snapshot(n)) end
    end

    local inputs = chain_inputs(epoch)
    report.epoch.inputs = #inputs
    report.oracle = { dir = ORACLE_DIR, snapshot = snapshot(target), keep = ORACLE_KEEP }
    say("epoch inputs   %d", #inputs)
    say("oracle         epoch %d starts at %s", target, snapshot(target))

    -- -----------------------------------------------------------------------
    -- 4. The honest commitment from the oracle snapshot, then one patched
    --    builder per sybil. Patch k garbles the leaf at meta_cycle k<<44:
    --    stride-aligned so it bites at level 0, distinct per sybil.
    -- -----------------------------------------------------------------------
    local machine, initial_state = load(target)
    local _, commitment = machine:rollup_commitment(LOG2_STRIDE, inputs)
    report.initial_machine_state_hash = hex(initial_state)
    report.honest_root = hex(commitment.root_hash)
    say("initial state  %s", hex(initial_state))
    say("honest root    %s", hex(commitment.root_hash))
    sh("rm -rf '%s'", scratch)

    local honest_builder = CommitmentBuilder:new(snapshot(target), inputs, commitment)

    local players = {}
    for k = 1, N_SYBILS do
        local builder = PatchedCommitmentBuilder:new(
            { { hash = Hash.zero, meta_cycle = k << LOG2_STRIDE } }, honest_builder)
        local pk_i = PK_INDEX + k - 1
        local pk = blockchain_consts.pks[pk_i]
            or fatal("no harness account at index %d (the bundled key table has %d entries;"
                .. " fewer sling nodes or sybils)", pk_i, #blockchain_consts.pks)
        local root = builder:build(uint256.zero(), 0, LOG2_STRIDE, ROOT_HEIGHT).root_hash
        if root == commitment.root_hash then fatal("sybil %d's patched root equals the honest root", k) end
        players[k] = {
            id = k,
            account = pk_i - 1,
            silent = k > N_SYBILS - N_SILENT,
            root = root,
            co = start_sybil(builder, snapshot(target), epoch.tournament, inputs, pk_i, {
                endpoint = RPC,
                pk = pk,
            }),
            done = false,
            lost = false,
        }
        report.sybils[k] = { id = k, account = pk_i - 1, silent = players[k].silent, root = hex(root) }
        say("sybil %d root   %s  (%s, account %d)", k, hex(root), players[k].silent and "silent" or "active", pk_i - 1)
    end

    -- -----------------------------------------------------------------------
    -- 5. Join phase: drive each sybil until the tournament's commitment count
    --    has grown to include it (the honest node's own join is counted too).
    -- -----------------------------------------------------------------------
    local function commitment_count(log)
        local n = 0
        for _ in pairs(log.state.commitments) do n = n + 1 end
        return n
    end

    for k = 1, N_SYBILS do
        local p = players[k]
        local rounds = 0
        while true do
            rounds = rounds + 1
            if rounds >= MAX_ROUNDS then fatal("sybil %d never joined", k) end
            local status, log = player_react(p.co)
            if status == "dead" then fatal("sybil %d died before joining", k) end
            if log.state and commitment_count(log) >= k + 1 then break end
            mine(1)
            time.sleep(1)
        end
        say("sybil %d joined  (%s)", k, p.silent and "will go silent" or "active")
    end

    local honest_joined = reader:commitment_exists(epoch.tournament, commitment.root_hash)
    check("honest commitment joined the root tournament", honest_joined, hex(commitment.root_hash))
    for _, p in ipairs(players) do
        p.joined = reader:commitment_exists(epoch.tournament, p.root)
        report.sybils[p.id].joined = p.joined
        check(string.format("sybil %d joined with its own root", p.id), p.joined, hex(p.root))
    end
    say("honest joined  %s", tostring(honest_joined))

    -- -----------------------------------------------------------------------
    -- 6. Dispute phase: active sybils react in turn; when every active one is
    --    idle, fast-forward gently so clocks actually move. Silent sybils are
    --    never driven again - their matches must expire on chain.
    -- -----------------------------------------------------------------------
    local active = 0
    for _, p in ipairs(players) do if not p.silent then active = active + 1 end end

    local rounds = 0
    while true do
        local remaining, idle = 0, true
        for _, p in ipairs(players) do
            if not p.silent and not p.done then
                local status, log = player_react(p.co)
                p.done = status == "dead" or (log and log.has_lost)
                p.lost = p.lost or (log and log.has_lost) or false
                if p.done then say("sybil %d finished  lost=%s", p.id, tostring(p.lost)) end
                if not p.done then
                    remaining = remaining + 1
                    idle = idle and (log and log.idle)
                end
            end
        end
        if remaining == 0 then break end
        rounds = rounds + 1
        if rounds >= MAX_ROUNDS then fatal("dispute did not converge within MAX_ROUNDS=%d", MAX_ROUNDS) end
        if idle then fast_forward(FF) end
    end
    say("all %d active sybils have finished", active)

    -- -----------------------------------------------------------------------
    -- 7. Wait for settlement: the next EpochSealed means this epoch was
    --    accepted. Silent matches expire on the way.
    -- -----------------------------------------------------------------------
    rounds = 0
    while true do
        local now = reader:read_epochs_sealed()
        if #now > target + 1 then break end
        rounds = rounds + 1
        if rounds >= MAX_ROUNDS then fatal("epoch %d never settled", target) end
        fast_forward(FF)
    end
    check(string.format("epoch %d settled (epoch %d sealed)", target, target + 1), true)

    -- -----------------------------------------------------------------------
    -- 8. Terminal state of every participant, from the chain - not from the
    --    coroutines, which silent players never resume.
    -- -----------------------------------------------------------------------
    local winner = reader:root_tournament_winner(epoch.tournament)
    report.winner = { has_winner = winner.has_winner, commitment = hex(winner.commitment), final_state = hex(winner.final) }
    check("root tournament finished with a winner", winner.has_winner)
    check("winner is the honest commitment", winner.has_winner and winner.commitment == commitment.root_hash,
        hex(winner.commitment))

    local deletions = reader:read_match_deleted(epoch.tournament)
    for i, d in ipairs(deletions) do
        report.matches_deleted[i] = {
            block = d.meta.block_number,
            commitment_one = hex(d.commitment_one),
            commitment_two = hex(d.commitment_two),
            reason = d.reason,
            winner = d.winner_commitment,
        }
    end

    local any_timeout = false
    for _, p in ipairs(players) do
        local eliminated, by_timeout, mine_deletions = false, false, {}
        for _, d in ipairs(deletions) do
            local is_one, is_two = d.commitment_one == p.root, d.commitment_two == p.root
            if is_one or is_two then
                local won = (is_one and d.winner_commitment == "one") or (is_two and d.winner_commitment == "two")
                mine_deletions[#mine_deletions + 1] = { reason = d.reason, won = won }
                if not won then
                    eliminated = true
                    if d.reason == "timeout" then by_timeout = true; any_timeout = true end
                end
            end
        end
        p.eliminated, p.by_timeout = eliminated, by_timeout
        local r = report.sybils[p.id]
        r.eliminated, r.eliminated_by_timeout, r.deletions = eliminated, by_timeout, mine_deletions
        r.actor_reported_loss = p.lost
        check(string.format("sybil %d eliminated on chain (MatchDeleted, not the winner)", p.id), eliminated,
            #mine_deletions == 0 and "no MatchDeleted names this root" or nil)
        if p.silent then
            check(string.format("silent sybil %d eliminated by timeout", p.id), by_timeout)
        else
            check(string.format("active sybil %d's actor reported the loss", p.id), p.lost)
        end
    end
    if N_SILENT > 0 then check("at least one root match ended by timeout", any_timeout) end

    -- -----------------------------------------------------------------------
    -- 9. Report.
    -- -----------------------------------------------------------------------
    say("")
    say("=== tournament %s (epoch %d) ===", epoch.tournament, epoch.epoch_number)
    say("has winner         %s", tostring(winner.has_winner))
    say("winner commitment  %s", hex(winner.commitment))
    say("honest commitment  %s", hex(commitment.root_hash))
    say("honest won         %s", tostring(winner.has_winner and winner.commitment == commitment.root_hash))
    for _, d in ipairs(deletions) do
        say("match deleted      reason=%s winner=%s", tostring(d.reason), tostring(d.winner_commitment))
    end
    for _, p in ipairs(players) do
        say("sybil %d            %-6s eliminated=%s%s", p.id, p.silent and "silent" or "active",
            tostring(p.eliminated), p.by_timeout and " (timeout)" or "")
    end
    say("")
    for _, c in ipairs(report.checks) do
        say("%s  %s%s", c.passed and "PASS" or "FAIL", c.name, c.detail and ("  [" .. c.detail .. "]") or "")
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    report.error = tostring(err)
    failures = failures + 1
    io.stderr:write("sybils: ", tostring(err), "\n")
end
report.ok = failures == 0
os.execute(string.format("rm -rf '%s' '%s'", ORACLE_DIR .. "/scratch", ORACLE_DIR .. "/actor-scratch"))
write_report()
if REPORT then say("report         %s", REPORT) end
say(report.ok and "RESULT         PASS" or string.format("RESULT         FAIL (%d)", failures))
os.exit(report.ok and 0 or 1)
