-- Feeds crisium-shaped (kind, message) pairs to the handler and checks what it writes.
-- Run through test.sh, which sets the environment the handler reads when it loads.
local log = assert(os.getenv("CRISIUM_ALERTS_LOG"))
os.remove(log)
local handle = require("crisium_alerts")
assert(type(handle) == "function", "the module must return a function, as crisium asserts")

local H1 = "0x" .. string.rep("a", 64)
local H2 = "0x" .. string.rep("b", 64)
local T = "0x" .. string.rep("1", 40)

-- Messages in the formats prt-bridge.lua and prt.lua use (machine-emulator v0.23.0).
local cases = {
    { "staged_tournament_result_mismatch",
        string.format("at epoch 3: staged state %s, outputs %s; local state %s, outputs %s", H1, H1, H2, H2),
        "guardian", true },
    { "sentry_claim_mismatch", string.format("at epoch 3: sentry %s claimed %s, locally computed %s", T, H1, H2),
        "guardian", true },
    { "execution_stopped", "at input 4: halted", "guardian", true },
    { "outputs_merkle_root_mismatch", "at input 2", "operator", true },
    { "unprovable_output", "at output 7", "operator", false },
    { "oversized_output", "at input 1", "operator", false },
    { "delegate_call_voucher", "delegate-call voucher selector at input 0, output 1", "warn", false },
    { "uarch_claim_failed", "at input 5, period 2: run_uarch raised", "operator", true },
    { "transition_verification_mismatch",
        string.format("at epoch 3, tournament %s, block 900: native accepted=true, Solidity accepted=false; expected %s, native result %s", T, H1, H2),
        "operator", true },
    { "staging_proof_failed", string.format("at epoch 3, tournament %s: bad proof", T), "operator", false },
    { "conflicting_claim", string.format("at %s: observed %s, locally computed %s", T, H1, H2), "warn", false },
    { "lost_match", string.format("at %s: local commitment %s eliminated", T, H2), "operator", true },
    { "unjoined_claim", "at tournament " .. T, "operator", false },
    { "deadline_near", "advanceMatch at " .. T .. ": its window closes at block 120", "operator", false },
    { "missed_deadline", "advanceMatch at " .. T .. ": its window closed at block 130", "operator", false },
    { "stalled_action", "stageTournamentResult at " .. T .. ": due since block 140", "warn", false },
    { "stalled_action", "tryRecoveringBond at " .. T .. ": due since block 150", "self", false },
    { "sentry_claim_missing", "at epoch 3: sentry " .. T .. " (ID 0) has not submitted a claim", "warn", false },
    { "falling_behind", "at input 9: 40 inputs pending", "warn", false },
    { "fee_ceiling", "at nonce 4", "self", false },
    { "insufficient_funds", "at nonce 4: needs 10 wei, has 1 wei", "self", false },
    { "some_future_kind", "at epoch 9", "operator", false },
}

local t0 = os.clock()
for _, c in ipairs(cases) do
    handle(c[1], c[2])
end
-- Repeats: the same job reported again (another block) collapses; another epoch does not.
handle("deadline_near", "advanceMatch at " .. T .. ": its window closes at block 121")
handle("execution_stopped", "at input 4: halted")
handle("execution_stopped", "at input 5: halted")
local elapsed = os.clock() - t0

local lines = {}
for line in io.lines(log) do
    lines[#lines + 1] = line
end
local expected = #cases + 1 -- the input 5 report is new; the two repeats are dropped
assert(#lines == expected, string.format("expected %d lines, got %d", expected, #lines))

local failures = 0
for i, c in ipairs(cases) do
    local line = lines[i]
    local ok = line:find('"kind":"' .. c[1] .. '"', 1, true)
        and line:find('"severity":"' .. c[3] .. '"', 1, true)
        and line:find('"foreclosure":' .. tostring(c[4]), 1, true)
    if c[4] then
        ok = ok and line:find('"signable":false', 1, true) and line:find('"second_verifier_answer"', 1, true)
    else
        ok = ok and not line:find('"signable"', 1, true)
    end
    if not ok then
        failures = failures + 1
        print("FAIL", c[1], c[2], line)
    end
end
assert(lines[1]:find('"epoch":"3"', 1, true) and lines[1]:find(H1, 1, true), "subject parsing")
assert(lines[14]:find('"job":"advanceMatch"', 1, true) and lines[14]:find('"block":"120"', 1, true), "job parsing")
assert(lines[#lines]:find('"input":"5"', 1, true), "distinct input kept")
assert(not lines[7]:find('"rts"', 1, true), "no internal references in alarms")
local runbook = os.getenv("CRISIUM_ALERTS_RUNBOOK")
if runbook and runbook ~= "" then
    assert(lines[1]:find('"runbook":"https://runbook.example/', 1, true), "runbook link per kind")
end
assert(failures == 0, failures .. " case(s) failed")
print(string.format("ok: %d cases, %d lines, %.1f ms CPU for %d calls", #cases, #lines, elapsed * 1000, #cases + 3))
