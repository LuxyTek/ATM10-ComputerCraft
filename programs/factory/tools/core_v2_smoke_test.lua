local ROOT = "/tmp/factory_v2_smoke"
local CORE = "/programs/factory/core"

local contract = dofile(CORE .. "/contract.lua")
local loader = dofile(CORE .. "/loader.lua")
local Registry = dofile(CORE .. "/registry.lua")
local adapter = dofile(CORE .. "/status_adapter.lua")

local function fail(message)
    printError("FAIL: " .. tostring(message))
    return false
end

local function writeFile(path, body)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle = fs.open(path, "w")
    if not handle then error("cannot write " .. path) end
    handle.write(body)
    handle.close()
end

if fs.exists(ROOT) then fs.delete(ROOT) end
fs.makeDir(ROOT)

writeFile(
    ROOT .. "/producer/definition.lua",
    [[return {
        contract=2,
        id="producer",
        label="PRODUCER",
        category="test",
        outputs={{id="oxygen"}},
        chains={{id="main",label="MAIN",machines={"machine"}}},
        machines={{id="machine",label="MACHINE",chain="main"}},
    }]]
)

writeFile(
    ROOT .. "/consumer/definition.lua",
    [[return {
        contract=2,
        id="consumer",
        label="CONSUMER",
        category="test",
        inputs={{id="oxygen"}},
    }]]
)

local definitions, listError = loader.listDefinitionFiles(ROOT)
if not definitions or #definitions ~= 2 then
    fs.delete(ROOT)
    return fail(listError or "loader did not discover two definitions")
end

local registry = Registry.new({ root=ROOT })
local ok, errors = registry:load()
if not ok then
    fs.delete(ROOT)
    return fail(errors[1] and errors[1].error or "registry load failed")
end

if #registry:list() ~= 2 then
    fs.delete(ROOT)
    return fail("registry count mismatch")
end

local topology = registry:topology()
if #topology ~= 1
    or topology[1].from ~= "producer"
    or topology[1].to ~= "consumer"
    or topology[1].resource ~= "oxygen" then
    fs.delete(ROOT)
    return fail("topology mismatch")
end

local legacy, legacyError = adapter.fromV1({
    contract=1,
    id="legacy",
    mode="AUTO",
    state="RUN",
    health="OK",
    runtimeState="ACTIVE",
    metrics={oxygen=0.5},
})

if not legacy then
    fs.delete(ROOT)
    return fail(legacyError)
end

local valid, validationError = contract.validateStatus(legacy)
if not valid then
    fs.delete(ROOT)
    return fail(validationError)
end

fs.delete(ROOT)

print("Factory Core V2 smoke test: OK")
print("Modules: " .. table.concat(registry:ids(), ", "))
print("Topology: producer --oxygen--> consumer")
print("Legacy V1 adapter: OK")
return true
