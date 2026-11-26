-- Preflight for crisium as a sentinel: stores the epoch-0 checkpoint from the application's template
-- and checks that the template is the application's (getTemplateHash), before crisium starts.
--
-- Usage: lua5.4 preflight.lua RPC APPLICATION DAVE_ARTIFACTS TEMPLATE_DIR CHECKPOINT_DIR
--
-- The geometry comes from the application's tournament factory, read as crisium.lua reads it. On
-- success it prints the template hash, which the entrypoint hands to the anomaly handler. On a template
-- mismatch it removes the checkpoint it just stored, so a corrected TEMPLATE_URL starts clean.
local cartesi = require("cartesi")
local evmu = require("cartesi.evmu")
local fs = require("cartesi.filesystem")
local json = require("dkjson")
local rpc_client = require("prt-rpc")
local eth = require("prt-ethereum")
local stored_player = require("prt-stored-player")
local bridge = require("prt-bridge")

local rpc, app, dave, template, checkpoint = table.unpack(arg)
assert(rpc and app and dave and template and checkpoint, "usage: preflight.lua RPC APP DAVE TEMPLATE CHECKPOINT")
app = app:lower()

local chain = rpc_client.new(rpc)
local function artifact(directory, name)
    return (eth.artifact(dave .. "/" .. directory .. "/contracts/out", name))
end
local abi = eth.abi({
    artifact("cartesi-rollups", "Application"),
    artifact("cartesi-rollups", "DaveConsensus"),
    artifact("cartesi-rollups", "InputBox"),
    artifact("prt", "Tournament"),
    artifact("prt", "MultiLevelTournamentFactory"),
})
local function call(address, name, types)
    return evmu.decode_abi(types, assert(eth.raw(assert(chain:call(address, abi:calldata(name, {}))))))[1]
end

local expected = assert(chain:call(app, abi:calldata("getTemplateHash", {})), "getTemplateHash() failed"):lower()
local consensus = call(app, "getOutputsMerkleRootValidator", "(address)"):lower()
local factory = call(consensus, "getTournamentFactory", "(address)"):lower()
local geometry = bridge.read_geometry(chain, abi, factory)

local created = not fs.exists(checkpoint)
stored_player.store_first_epoch_checkpoint(template, geometry, checkpoint)
local manifest = assert(json.decode(assert(fs.read_file(checkpoint .. "/epoch.json"))), "unreadable epoch.json")
local actual = manifest.final_state_hash:lower()
if actual ~= expected then
    if created then
        os.execute(string.format("rm -rf '%s'", checkpoint))
    end
    io.stderr:write(
        string.format(
            "template mismatch: the template's hash is %s, but application %s has getTemplateHash() = %s\n",
            actual,
            app,
            expected
        )
    )
    os.exit(2)
end
io.stderr:write(
    string.format(
        "preflight ok: application %s, consensus %s, factory %s, template %s, epoch-0 checkpoint %s\n",
        app,
        consensus,
        factory,
        actual,
        created and "stored" or "already present"
    )
)
print(actual)
