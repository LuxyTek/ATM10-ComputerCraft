local M = {}

local function ratioMetric(packet,id)
    local metrics=type(packet.metrics)=="table" and packet.metrics or {}
    local value=metrics[id]
    if type(value)=="number" then
        return math.max(0,math.min(1,value))
    end
    return nil
end

local function normalizeLineId(lineId)
    local number=tostring(lineId or ""):match("(%d+)")
    if not number then return nil end
    return "line_"..number
end

local function machineId(machine)
    local chainId=normalizeLineId(machine.lineId)
    if not chainId then return nil end

    if machine.kind=="PUMP" then
        return chainId.."_pump"
    elseif machine.kind=="SEP" then
        return chainId.."_separator"
    end

    return nil
end

local function machineStatus(machine)
    local result={
        peripheral=machine.name,
        kind=machine.kind,
        state=machine.state or "UNKNOWN",
        controllable=true,

        fluidFill=machine.fluidFill,
        waterFill=machine.waterFill,
        hydrogenFill=machine.hydrogenFill,
        oxygenFill=machine.oxygenFill,

        hydrogenSide=machine.hydrogenSide,
        oxygenSide=machine.oxygenSide,
        leftFill=machine.leftFill,
        rightFill=machine.rightFill,
        leftChemical=machine.leftChemical,
        rightChemical=machine.rightChemical,
        leftDumpMode=machine.leftDumpMode,
        rightDumpMode=machine.rightDumpMode,

        legacyLineId=machine.lineId,
    }

    if type(machine.energy)=="number" then result.energy=machine.energy end
    if type(machine.maxEnergy)=="number" then result.maxEnergy=machine.maxEnergy end
    if type(machine.energyUsage)=="number" then result.energyUsage=machine.energyUsage end

    return result
end

local function buildChains(packet)
    local chains={}
    local lines=
        type(packet.ui)=="table"
        and type(packet.ui.lines)=="table"
        and packet.ui.lines
        or {}

    for _,line in ipairs(lines) do
        local id=normalizeLineId(line.id)
        if id then
            chains[id]={
                enabled=true,
                state=line.state or "UNKNOWN",
                reason=line.state or "UNKNOWN",
                legacyId=line.id,
            }
        end
    end

    return chains
end

local function buildMachines(packet)
    local machines={}
    local legacy=
        type(packet.ui)=="table"
        and type(packet.ui.machines)=="table"
        and packet.ui.machines
        or {}

    for _,machine in ipairs(legacy) do
        local id=machineId(machine)
        if id then machines[id]=machineStatus(machine) end
    end

    return machines
end

function M.fromLegacy(packet)
    if type(packet)~="table"
        or packet.contract~=1
        or packet.id~="h2o2" then
        return nil,"expected legacy h2o2 contract v1 packet"
    end

    local water=ratioMetric(packet,"water")
    local hydrogen=ratioMetric(packet,"hydrogen")
    local oxygen=ratioMetric(packet,"oxygen")

    local resources={
        water={fill=water},
        hydrogen={fill=hydrogen},
        oxygen={fill=oxygen},
    }

    local runtime=tostring(packet.runtimeState or "")
    if runtime=="" then
        runtime=packet.health=="FAULT" and "FAULT"
            or packet.state=="RUN" and "ACTIVE"
            or "IDLE"
    end

    local ui=type(packet.ui)=="table" and packet.ui or {}

    return {
        contract=2,
        id="h2o2",
        label=packet.label or "H2/O2",
        category=packet.type or "process",
        version=packet.version,

        runtime=runtime,
        mode=packet.mode or "UNKNOWN",
        state=packet.state or "UNKNOWN",
        health=packet.health or "UNKNOWN",
        reason=packet.reason or "-",

        metrics={
            water=water,
            hydrogen=hydrogen,
            oxygen=oxygen,
        },

        resources=resources,
        chains=buildChains(packet),
        machines=buildMachines(packet),
        alarms=packet.alarms or {},

        module={
            activeLines=packet.activeLines,
            totalLines=packet.totalLines,
            targetLines=ui.targetLines,
            energy=ui.energy,
            maxEnergy=ui.maxEnergy,
            energyUsage=ui.usage,
            controlState=ui.controlState,
            separatorResponding=ui.separatorResponding,
            separatorRunning=ui.separatorRunning,
        },

        legacy={
            contract=1,
            packet=packet,
        },
    }
end

return M
