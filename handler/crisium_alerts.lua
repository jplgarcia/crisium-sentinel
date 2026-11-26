-- crisium_alerts: an --anomaly-handler module for crisium (machine-emulator v0.23.0,
-- doc/recipes/crisium.lua). crisium calls the function this module returns with (kind, message)
-- for every anomaly, synchronously, inside a pass, so it must return quickly. This handler:
--
--   1. classifies the anomaly (severity, recipients, a summary and a suggested action);
--   2. parses the subject out of the message (epoch, tournament, input, block, hashes);
--   3. drops a repeat of the same kind and subject within a time window;
--   4. appends one JSON line per anomaly to a file;
--   5. optionally posts a short text to a webhook, in the background, never waiting for it.
--
-- It never asks anyone to foreclose on crisium alone. An alarm that may lead to foreclosure is marked
-- "signable": false and lists what a signer still needs (a second verifier's answer, the acceptance
-- status, the chain view): one detector's opinion is not enough to sign a foreclosure.
--
-- Configuration, all through environment variables read once when the module loads:
--   CRISIUM_ALERTS_LOG              JSON lines file (default ./crisium-anomalies.jsonl)
--   CRISIUM_ALERTS_WEBHOOK          webhook URL; unset means no network at all
--   CRISIUM_ALERTS_WEBHOOK_FORMAT   discord (default) or slack
--   CRISIUM_ALERTS_WEBHOOK_MIN      lowest severity posted: guardian, operator, warn (default), self.
--                                   warn alarms still name people (defenders, operator); self stays in the log.
--   CRISIUM_ALERTS_DEDUPE_SECONDS   repeat window per kind and subject (default 600; 0 disables)
--   CRISIUM_ALERTS_SOURCE           detector name in the alarm (default "crisium sentinel")
--   CRISIUM_ALERTS_VERSION          emulator/crisium version or commit, for the alarm
--   CRISIUM_ALERTS_TEMPLATE_HASH    the application's template hash, for the alarm
--   CRISIUM_ALERTS_PROVIDER         the RPC provider crisium reads, for the alarm
--   CRISIUM_ALERTS_CURL             curl binary (default "curl")
--   CRISIUM_ALERTS_RUNBOOK          optional runbook URL for each alarm; "{kind}" is replaced by the kind

local getenv = os.getenv

local config = {
    log = getenv("CRISIUM_ALERTS_LOG") or "crisium-anomalies.jsonl",
    webhook = getenv("CRISIUM_ALERTS_WEBHOOK"),
    webhook_format = getenv("CRISIUM_ALERTS_WEBHOOK_FORMAT") or "discord",
    webhook_min = getenv("CRISIUM_ALERTS_WEBHOOK_MIN") or "warn",
    dedupe_seconds = tonumber(getenv("CRISIUM_ALERTS_DEDUPE_SECONDS") or "600") or 600,
    source = getenv("CRISIUM_ALERTS_SOURCE") or "crisium sentinel",
    version = getenv("CRISIUM_ALERTS_VERSION"),
    template_hash = getenv("CRISIUM_ALERTS_TEMPLATE_HASH"),
    provider = getenv("CRISIUM_ALERTS_PROVIDER"),
    curl = getenv("CRISIUM_ALERTS_CURL") or "curl",
    runbook = getenv("CRISIUM_ALERTS_RUNBOOK"),
}
if config.webhook == "" then
    config.webhook = nil
end

-- Severity order: guardian > operator > warn > self.
local RANK = { guardian = 4, operator = 3, warn = 2, self = 1 }

local GUARDIAN = { "guardian signers", "operator on-call" }
local OPERATOR = { "operator on-call" }
local DEFENDERS = { "defenders on-call (sling operator)" }
local EMULATOR = { "operator on-call", "emulator team" }
local SELF = { "crisium operator" }

-- Every kind in prt-lua-bridge.md's anomaly table (machine-emulator v0.23.0).
-- foreclosure: the anomaly can end in a foreclosure decision, so the alarm is never signable alone.
local KINDS = {
    staged_tournament_result_mismatch = {
        severity = "guardian", recipients = GUARDIAN, foreclosure = true,
        summary = "A staged result differs from crisium's replay.",
        action = "Cross-check the epoch's final state with a second implementation (Go node, CLI) before "
            .. "acceptance; read canAcceptStagedTournamentResult: with every sentry agreeing, acceptance "
            .. "does not wait for the staging period.",
    },
    sentry_claim_mismatch = {
        severity = "guardian", recipients = { "guardian signers", "sling operator" }, foreclosure = true,
        summary = "A registered sentry voted a state that differs from crisium's replay.",
        action = "Find which side the second verifier agrees with. If the vote is for the staged hash, the "
            .. "fast path may be open on a wrong result; the deadline is the staging block plus P.",
    },
    execution_stopped = {
        severity = "guardian", recipients = GUARDIAN, foreclosure = true,
        summary = "The machine stopped on an input (halt, cycle limit, exception or unexpected yield).",
        action = "Confirm with the Go node's input status and an independent replay. Prepare to foreclose "
            .. "only if both say terminal and nobody defends the root.",
    },
    outputs_merkle_root_mismatch = {
        severity = "operator", recipients = OPERATOR, foreclosure = true,
        summary = "The outputs root the machine wrote differs from the root of its outputs.",
        action = "Decide machine or node with a replay that does not use the node, before PRT settles the "
            .. "root. Machine wrong: escalate to the guardian. Node wrong: fix the node, do not foreclose.",
    },
    unprovable_output = {
        severity = "operator", recipients = OPERATOR, foreclosure = false,
        summary = "An output does not prove against the settled machine's root.",
        action = "Users cannot withdraw with this output's proof. Check the outputs and the settled root.",
    },
    oversized_output = {
        severity = "operator", recipients = OPERATOR, foreclosure = false,
        summary = "An output declared a length larger than the TX buffer.",
        action = "PRT keeps settling; the Go node stops and the epoch's outputs may have no proofs. "
            .. "Keep defending the true commitment and tell the app's developers.",
    },
    delegate_call_voucher = {
        severity = "warn", recipients = OPERATOR, foreclosure = false,
        summary = "An output carries the DelegateCallVoucher selector.",
        action = "Expected for apps whose withdrawals are delegate-call vouchers; unexpected otherwise.",
    },
    uarch_claim_failed = {
        severity = "operator", recipients = EMULATOR, foreclosure = true,
        summary = "Building a uarch claim failed.",
        action = "If the dispute reaches this span, the honest claim may not be provable. Replay native and "
            .. "uarch at the disputed mcycle on the deployed emulator release before any decision.",
    },
    transition_verification_mismatch = {
        severity = "operator", recipients = EMULATOR, foreclosure = true,
        summary = "Native verification and the Solidity step disagree on a leaf proof.",
        action = "Emulator or step bug; keep the evidence and stop before any foreclosure decision.",
    },
    staging_proof_failed = {
        severity = "operator", recipients = OPERATOR, foreclosure = false,
        summary = "The winning state's outputs-root proof failed local validation.",
        action = "The won result cannot be staged from here. Check the machine state and the proof.",
    },
    conflicting_claim = {
        severity = "warn", recipients = DEFENDERS, foreclosure = false,
        summary = "A commitment joined that differs from crisium's.",
        action = "A dispute started. Compare the join's finalStateHash with ours (crisium compares only the "
            .. "commitment): same final state is griefing; a different one needs the defenders up and on time.",
    },
    lost_match = {
        severity = "operator", recipients = { "operator on-call", "leads" }, foreclosure = true,
        summary = "A match of crisium's commitment was lost.",
        action = "Compute the final state with two verifiers that are not the sling. Sling wrong: restore it, "
            .. "do not foreclose. Winner wrong: escalate to the guardian.",
    },
    unjoined_claim = {
        severity = "operator", recipients = DEFENDERS, foreclosure = false,
        summary = "A joining window closed without crisium's commitment on-chain.",
        action = "Nobody joined the expected commitment. Check the sling and the Go node claimer, and whether "
            .. "a rival is now unopposed.",
    },
    deadline_near = {
        severity = "operator", recipients = DEFENDERS, foreclosure = false,
        summary = "An honest action is missing and its window closes soon.",
        action = "Check the sling is up and its moves land; restart it, switch RPC or top up the signer, or "
            .. "start a standby player.",
    },
    missed_deadline = {
        severity = "operator", recipients = { "defenders on-call (sling operator)", "leads" },
        foreclosure = false,
        summary = "An honest action's window closed without it.",
        action = "The honest commitment may be eliminated. Check the match outcome (lost_match) next.",
    },
    stalled_action = {
        severity = "warn", recipients = OPERATOR, foreclosure = false,
        summary = "An action without a window (staging, acceptance, bond recovery) is overdue.",
        action = "Settlement is stalled, not wrong. Restore a sender or call it from another account.",
    },
    sentry_claim_missing = {
        severity = "warn", recipients = OPERATOR, foreclosure = false,
        summary = "A registered sentry has not voted on a staged epoch.",
        action = "No early acceptance; acceptance after the staging period is not vetoed.",
    },
    falling_behind = {
        severity = "warn", recipients = SELF, foreclosure = false,
        summary = "crisium has more pending inputs than its machine cache spans.",
        action = "Its alarms may come late; check the host's capacity.",
    },
    fee_ceiling = {
        severity = "self", recipients = SELF, foreclosure = false,
        summary = "A transaction reached the fee ceiling (validator mode).",
        action = "Raise the fee limits or wait; the nonce is kept.",
    },
    insufficient_funds = {
        severity = "self", recipients = SELF, foreclosure = false,
        summary = "The signer cannot pay a transaction (validator mode).",
        action = "Top up the signer.",
    },
}

local UNKNOWN = {
    severity = "operator", recipients = OPERATOR, foreclosure = false,
    summary = "An anomaly kind this handler does not know.",
    action = "Update the handler's table for this crisium version.",
}

-- Some sentinel kinds depend on the job: an overdue bond recovery is only the sentinel's own concern.
local function refine(kind, rule, subject)
    local job = subject and subject.job
    if not job then
        return rule
    end
    if kind == "stalled_action" and job == "tryRecoveringBond" then
        local r = {}
        for k, v in pairs(rule) do
            r[k] = v
        end
        r.severity = "self"
        r.summary = "A bond recovery is overdue."
        return r
    end
    return rule
end

local HASH = "0x" .. string.rep("%x", 64)

local function parse(message)
    local s = {}
    s.job, s.address = message:match("^(%a+) at (0x%x+)")
    s.epoch = message:match("epoch (%d+)")
    s.tournament = message:match("tournament (0x%x+)") or message:match("^at (0x%x+)")
    s.input = message:match("input (%d+)")
    s.output = message:match("output (%d+)")
    s.block = message:match("block (%d+)")
    s.nonce = message:match("nonce (%d+)")
    s.sentry = message:match("sentry (0x%x+)")
    local hashes = {}
    for h in message:gmatch(HASH) do
        hashes[#hashes + 1] = h
    end
    if #hashes > 0 then
        s.hashes = hashes
    end
    return s
end

-- Subject for deduplication: the message with block numbers removed, so the same job reported again
-- after a restart or reorg collapses, while a different epoch, tournament or input does not.
local function dedupe_key(kind, message)
    return kind .. "|" .. message:gsub("block %d+", "block _")
end

-- Minimal JSON encoder (strings, numbers, booleans, arrays, objects), so the module has no dependency.
local function encode(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return (v == math.floor(v)) and string.format("%d", v) or string.format("%.17g", v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
            return map[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "table" then
        if next(v) == nil then
            return "[]"
        end
        if #v > 0 then
            local out = {}
            for i = 1, #v do
                out[i] = encode(v[i])
            end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do
            out[#out + 1] = encode(tostring(k)) .. ":" .. encode(v[k])
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return '"' .. tostring(v) .. '"'
end

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Fire-and-forget: write the payload to a temporary file and let a background curl send and remove it.
local function post(alarm)
    if not config.webhook or RANK[alarm.severity] < (RANK[config.webhook_min] or RANK.warn) then
        return
    end
    local text = string.format(
        "[%s] %s: %s %s%s",
        alarm.severity,
        alarm.source,
        alarm.kind,
        alarm.message,
        alarm.foreclosure and " | NOT signable alone: needs a second verifier and the acceptance status" or ""
    )
    local body = config.webhook_format == "slack" and encode({ text = text }) or encode({ content = text })
    local path = os.tmpname()
    local f = io.open(path, "w")
    if not f then
        return
    end
    f:write(body)
    f:close()
    local cmd = string.format(
        "(%s -s -m 10 -H 'Content-Type: application/json' --data-binary @%s %s >/dev/null 2>&1; rm -f %s) &",
        config.curl,
        shell_quote(path),
        shell_quote(config.webhook),
        shell_quote(path)
    )
    os.execute(cmd)
end

local seen = {}

local function handle(kind, message)
    message = tostring(message or "")
    local now = os.time()
    if config.dedupe_seconds > 0 then
        local key = dedupe_key(kind, message)
        local last = seen[key]
        if last and now - last < config.dedupe_seconds then
            return
        end
        seen[key] = now
    end
    local subject = parse(message)
    if next(subject) == nil then
        subject = nil
    end
    local rule = refine(kind, KINDS[kind] or UNKNOWN, subject)
    local alarm = {
        time = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
        source = config.source,
        kind = kind,
        known_kind = KINDS[kind] ~= nil,
        message = message,
        subject = subject,
        severity = rule.severity,
        recipients = rule.recipients,
        summary = rule.summary,
        action = rule.action,
        foreclosure = rule.foreclosure,
    }
    if config.runbook and config.runbook ~= "" then
        alarm.runbook = (config.runbook:gsub("{kind}", kind))
    end
    if rule.foreclosure then
        -- A signer does not sign an alarm with a missing field. crisium supplies one opinion and
        -- none of the chain context, so the alarm is never signable as it leaves the handler.
        alarm.signable = false
        alarm.missing = {
            "second_verifier_answer",
            "acceptance_status (canAcceptStagedTournamentResult, sentry votes, staging block + P)",
            "head_block_and_time",
        }
        alarm.detector = {
            name = config.source,
            version = config.version or "unset",
            template_hash = config.template_hash or "unset",
            provider = config.provider or "unset",
        }
    end
    local f = io.open(config.log, "a")
    if f then
        f:write(encode(alarm), "\n")
        f:close()
    end
    post(alarm)
end

return handle
