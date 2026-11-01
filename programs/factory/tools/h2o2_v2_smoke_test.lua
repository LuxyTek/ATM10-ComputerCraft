local MODULE="/programs/factory/modules/h2o2"
local CORE="/programs/factory/core"
local UI="/programs/factory/ui"

local contract=dofile(CORE.."/contract.lua")
local adapter=dofile(MODULE.."/legacy_adapter.lua")
local definition=dofile(MODULE.."/definition.lua")
local overview=dofile(UI.."/overview.lua")
local machines=dofile(UI.."/machines.lua")

local valid,validationError=contract.validateDefinition(definition)
if not valid then
    printError("Definition H2/O2 invalide: "..tostring(validationError))
    return false
end

local legacy={
    contract=1,
    id="h2o2",
    label="H2/O2",
    type="process",
    version="0.9.4",
    mode="MANUAL",
    state="RUN",
    health="OK",
    runtimeState="ACTIVE",
    reason="TEST V2",
    activeLines=2,
    totalLines=3,
    metrics={
        water=0.92,
        hydrogen=0.46,
        oxygen=0.68,
    },
    ui={
        targetLines=2,
        energy=120000,
        maxEnergy=300000,
        usage=240,
        controlState="MIXED",
        lines={
            {id="LINE 1",state="RUN"},
            {id="LINE 2",state="RUN"},
            {id="LINE 3",state="STOP"},
        },
        machines={
            {
                kind="PUMP",
                name="electricPump_2",
                lineId="LINE 1",
                state="RUN",
                fluidFill=0.95,
            },
            {
                kind="SEP",
                name="electrolyticSeparator_2",
                lineId="LINE 1",
                state="RUN",
                waterFill=0.90,
                hydrogenFill=0.40,
                oxygenFill=0.60,
                leftDumpMode="IDLE",
                rightDumpMode="IDLE",
            },
            {
                kind="PUMP",
                name="electricPump_1",
                lineId="LINE 2",
                state="RUN",
                fluidFill=0.88,
            },
            {
                kind="SEP",
                name="electrolyticSeparator_0",
                lineId="LINE 2",
                state="RUN",
                waterFill=0.85,
                hydrogenFill=0.45,
                oxygenFill=0.65,
                leftDumpMode="IDLE",
                rightDumpMode="DUMPING_EXCESS",
            },
            {
                kind="PUMP",
                name="electricPump_0",
                lineId="LINE 3",
                state="STOP",
                fluidFill=0.70,
            },
            {
                kind="SEP",
                name="electrolyticSeparator_1",
                lineId="LINE 3",
                state="STOP",
                waterFill=0.70,
                hydrogenFill=0.30,
                oxygenFill=0.50,
                leftDumpMode="IDLE",
                rightDumpMode="IDLE",
            },
        },
    },
    alarms={},
}

local status,adaptError=adapter.fromLegacy(legacy)
if not status then
    printError("Adaptation H2/O2 echouee: "..tostring(adaptError))
    return false
end

valid,validationError=contract.validateStatus(status)
if not valid then
    printError("Status H2/O2 V2 invalide: "..tostring(validationError))
    return false
end

local expectedMachines={
    "line_1_pump",
    "line_1_separator",
    "line_2_pump",
    "line_2_separator",
    "line_3_pump",
    "line_3_separator",
}

for _,id in ipairs(expectedMachines) do
    if type(status.machines[id])~="table" then
        printError("Machine logique absente: "..id)
        return false
    end
end

for _,id in ipairs({"line_1","line_2","line_3"}) do
    if type(status.chains[id])~="table" then
        printError("Chaine logique absente: "..id)
        return false
    end
end

local args={...}
local view=tostring(args[1] or "overview"):lower()
local target=term.current()

local display=tostring(args[2] or ""):lower()
if display=="monitor" then
    local found=peripheral.find("monitor")
    if found then
        target=found
        pcall(target.setTextScale,0.5)
    else
        printError("Aucun monitor detecte, utilisation du terminal.")
    end
end

if view=="machines" then
    machines.render(target,definition,status,{})
else
    overview.render(target,definition,status,{})
end

if target~=term.current() then
    print("H2/O2 V2 smoke test: OK")
    print("Vue: "..view)
else
    print("")
    print("H2/O2 V2 smoke test: OK")
end

return true
