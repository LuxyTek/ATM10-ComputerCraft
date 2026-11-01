local ROOT="/tmp/factory_v2_ui_smoke"
local CORE="/programs/factory/core"
local UI="/programs/factory/ui"

local Registry=dofile(CORE.."/registry.lua")
local overview=dofile(UI.."/overview.lua")
local machines=dofile(UI.."/machines.lua")
local flowMap=dofile(UI.."/flow_map.lua")

local function writeFile(path,body)
    local parent=fs.getDir(path)
    if parent~="" and not fs.exists(parent) then fs.makeDir(parent) end

    local handle=fs.open(path,"w")
    if not handle then error("cannot write "..path) end
    handle.write(body)
    handle.close()
end

if fs.exists(ROOT) then fs.delete(ROOT) end
fs.makeDir(ROOT)

writeFile(ROOT.."/source/definition.lua",[[
return {
    contract=2,
    id="source",
    label="SOURCE",
    category="test",
    outputs={{id="oxygen",label="OXYGEN"}},
    chains={{
        id="generation",
        label="GENERATION",
        controllable=true,
        machines={"generator"},
    }},
    machines={{
        id="generator",
        label="GENERATOR",
        chain="generation",
    }},
    actions={
        ["chain.set_enabled"]=true,
        ["machine.start"]=true,
        ["machine.stop"]=true,
    },
}
]])

writeFile(ROOT.."/process/definition.lua",[[
return {
    contract=2,
    id="process",
    label="PROCESS",
    category="test",
    inputs={{id="oxygen",label="OXYGEN"}},
    outputs={{id="product",label="PRODUCT"}},
    chains={{
        id="reaction",
        label="REACTION",
        controllable=true,
        machines={"reactor"},
    },{
        id="future",
        label="FUTURE CHAIN",
        controllable=false,
        machines={},
    }},
    machines={{
        id="reactor",
        label="REACTOR",
        chain="reaction",
    }},
    actions={
        ["chain.set_enabled"]=true,
        ["machine.start"]=true,
        ["machine.stop"]=true,
    },
}
]])

local registry=Registry.new({root=ROOT})
local ok,errors=registry:load()
if not ok then
    fs.delete(ROOT)
    printError(errors[1] and errors[1].error or "registry failed")
    return false
end

local statuses={
    source={
        contract=2,
        id="source",
        version="test",
        runtime="ACTIVE",
        mode="AUTO",
        state="RUN",
        health="OK",
        reason="PRODUCTION",
        resources={oxygen={fill=0.82}},
        metrics={oxygen=0.82},
        chains={generation={enabled=true,state="RUN"}},
        machines={
            generator={
                peripheral="testGenerator_0",
                state="RUN",
                energy=80000,
                maxEnergy=100000,
                energyUsage=120,
                controllable=true,
            },
        },
    },
    process={
        contract=2,
        id="process",
        version="test",
        runtime="ACTIVE",
        mode="MANUAL",
        state="RUN",
        health="OK",
        reason="PRODUCTION",
        resources={
            oxygen={fill=0.64},
            product={fill=0.35},
        },
        metrics={oxygen=0.64,product=0.35},
        chains={
            reaction={enabled=true,state="RUN"},
            future={enabled=true,state="IDLE"},
        },
        machines={
            reactor={
                peripheral="testReactor_0",
                state="RUN",
                energy=50000,
                maxEnergy=100000,
                energyUsage=80,
                controllable=true,
            },
        },
    },
}

local args={...}
local view=tostring(args[1] or "flow"):lower()
local target=term.current()

if view=="overview" then
    overview.render(target,registry:get("process"),statuses.process,{
        allowChainControls=true,
    })
elseif view=="machines" then
    machines.render(target,registry:get("process"),statuses.process,{})
else
    flowMap.render(target,registry,statuses,{})
end

fs.delete(ROOT)

term.setCursorPos(1,select(2,term.getSize()))
term.setTextColor(colors.lightGray)
term.setBackgroundColor(colors.black)

return true
