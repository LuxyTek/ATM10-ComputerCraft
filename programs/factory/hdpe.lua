local PROGRAM_VERSION = "0.1.0"
local STATUS_BUS_PATH = "/programs/factory/lib/status_bus.lua"
local CONFIG_PATH = "/config/factory_hdpe.lua"

local defaults = {
    stopMode = "HIGH",

    prc = "pressurizedReactionChamber_4",
    outputBarrel = "sophisticatedstorage:barrel_3",
    outputCapacity = 270336,

    auto = {
        outputStop = 0.95,
        outputResume = 0.80,
    },

    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },

    status = {
        publishSeconds = 2,
        id = "hdpe",
        label = "HDPE",
        type = "process",
    },
}

local function mergeMissing(target, source)
    for key, value in pairs(source) do
        if target[key] == nil then
            target[key] = value
        elseif type(target[key]) == "table" and type(value) == "table" then
            mergeMissing(target[key], value)
        end
    end
end

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return defaults end

    local ok, cfg = pcall(dofile, CONFIG_PATH)
    if not ok or type(cfg) ~= "table" then return defaults end

    mergeMissing(cfg, defaults)
    return cfg
end

local config = loadConfig()

local operatingMode = "AUTO"
local dataCache = nil

local runtimeState = {
    state = "ACTIVE",
    wakeReason = "BOOT",
    lastPoll = 0,
}

local autoState = {
    outputHold = nil,
    sleepHold = false,
    reason = "AUTO INIT",
}

local function safeCall(device, method, ...)
    if not device or type(device[method]) ~= "function" then return nil end
    local ok, result = pcall(device[method], ...)
    if ok then return result end
    return nil
end

local function ratio(value, maximum)
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
        return nil
    end
    return math.max(0, math.min(1, value / maximum))
end

local function stateFromMode(mode)
    if mode == "DISABLED" then return "RUN" end
    if mode == config.stopMode then return "STOP" end
    if mode == nil then return "UNKNOWN" end
    return "WARN"
end

local function callFirstAvailable(device, methods)
    if not device then return nil, false, nil end

    for _, method in ipairs(methods) do
        if type(device[method]) == "function" then
            local ok, value = pcall(device[method])
            if ok then
                return value, true, method
            end
            return nil, false, method
        end
    end

    return nil, false, nil
end

local function summarizeBarrel(name)
    if not peripheral.isPresent(name) then
        return {
            present=false,
            readable=false,
            count=0,
            itemName=nil,
            mixed=false,
        }
    end

    local dev = peripheral.wrap(name)
    local items = safeCall(dev, "list")

    if type(items) ~= "table" then
        return {
            present=true,
            readable=false,
            count=0,
            itemName=nil,
            mixed=false,
        }
    end

    local total = 0
    local dominantName = nil
    local dominantCount = -1
    local distinct = {}

    for _, item in pairs(items) do
        if type(item) == "table" then
            local count = tonumber(item.count) or 0
            total = total + count

            if type(item.name) == "string" then
                distinct[item.name] = true
                if count > dominantCount then
                    dominantCount = count
                    dominantName = item.name
                end
            end
        end
    end

    local distinctCount = 0
    for _ in pairs(distinct) do
        distinctCount = distinctCount + 1
    end

    return {
        present=true,
        readable=true,
        count=total,
        itemName=dominantName,
        mixed=distinctCount > 1,
    }
end

local function readPrc()
    if not peripheral.isPresent(config.prc) then
        return {
            present=false,
            state="ABSENT",
        }
    end

    local prc = peripheral.wrap(config.prc)
    local inputItem, inputItemReadable =
        callFirstAvailable(prc, {"getInputItem"})

    local inputFluidFill, inputFluidReadable =
        callFirstAvailable(prc, {
            "getInputFluidFilledPercentage",
            "getFluidFilledPercentage",
        })

    local inputGasFill, inputGasReadable =
        callFirstAvailable(prc, {
            "getInputGasFilledPercentage",
            "getGasFilledPercentage",
        })

    local outputItem, outputItemReadable =
        callFirstAvailable(prc, {"getOutputItem"})

    local substrateCount = nil
    local substrateName = nil

    if inputItemReadable then
        if type(inputItem) == "table" then
            substrateCount = tonumber(inputItem.count) or 0
            substrateName = inputItem.name
        else
            substrateCount = 0
        end
    end

    return {
        present=true,
        state=stateFromMode(safeCall(prc, "getRedstoneMode")),

        substrateReadable=inputItemReadable,
        substrateCount=substrateCount,
        substrateName=substrateName,

        liquidEtheneReadable=inputFluidReadable and type(inputFluidFill) == "number",
        liquidEtheneFill=type(inputFluidFill) == "number" and inputFluidFill or nil,

        oxygenReadable=inputGasReadable and type(inputGasFill) == "number",
        oxygenFill=type(inputGasFill) == "number" and inputGasFill or nil,

        outputItemReadable=outputItemReadable,
        outputItem=outputItem,

        energy=safeCall(prc, "getEnergy"),
        maxEnergy=safeCall(prc, "getMaxEnergy"),
        energyUsage=safeCall(prc, "getEnergyUsage"),
    }
end

local function collectData()
    local prc = readPrc()
    local output = summarizeBarrel(config.outputBarrel)

    return {
        prc=prc,
        output=output,
        outputFill=ratio(output.count, config.outputCapacity),
        online=prc.present and output.present,
    }
end

local function setPrcMode(targetMode)
    if not peripheral.isPresent(config.prc) then
        return false
    end

    local prc = peripheral.wrap(config.prc)
    if not prc or type(prc.setRedstoneMode) ~= "function" then
        return false
    end

    return pcall(prc.setRedstoneMode, targetMode)
end

local function inputUnavailable(prc)
    if prc.substrateReadable and (tonumber(prc.substrateCount) or 0) <= 0 then
        return "HOLD SUBSTRATE"
    end

    if prc.liquidEtheneReadable and (tonumber(prc.liquidEtheneFill) or 0) <= 0 then
        return "HOLD LIQ ETHENE"
    end

    if prc.oxygenReadable and (tonumber(prc.oxygenFill) or 0) <= 0 then
        return "HOLD O2"
    end

    return nil
end

local function applyAuto(data)
    if operatingMode ~= "AUTO" then return end

    autoState.sleepHold = false

    if not data.online then
        autoState.reason = "FAULT PERIPHERAL"
        setPrcMode(config.stopMode)
        return
    end

    local outputFill = data.outputFill or 0

    if autoState.outputHold == nil then
        autoState.outputHold =
            data.prc.state == "STOP"
            and outputFill > config.auto.outputResume
    end

    if autoState.outputHold then
        if outputFill <= config.auto.outputResume then
            autoState.outputHold = false
            os.queueEvent("factory_module_wake", "hdpe", "AUTO_RESUME")
        else
            autoState.sleepHold = true
            autoState.reason = ("BUFFER HOLD %.0f%%"):format(outputFill * 100)
            setPrcMode(config.stopMode)
            return
        end
    elseif outputFill >= config.auto.outputStop then
        autoState.outputHold = true
        autoState.sleepHold = true
        autoState.reason = ("BUFFER FULL %.0f%%"):format(outputFill * 100)
        setPrcMode(config.stopMode)
        return
    end

    local inputHold = inputUnavailable(data.prc)
    if inputHold then
        autoState.reason = inputHold
        setPrcMode(config.stopMode)
        return
    end

    autoState.reason = "PRODUCTION"
    if data.prc.state ~= "RUN" then
        setPrcMode("DISABLED")
    end
end

local function moduleState(data)
    if not data or not data.online then return "STOP" end
    if data.prc.state == "RUN" then return "RUN" end

    if operatingMode == "AUTO" and (
        autoState.outputHold
        or tostring(autoState.reason):find("HOLD", 1, true)
        or tostring(autoState.reason):find("FAULT", 1, true)
    ) then
        return "HOLD"
    end

    return "STOP"
end

local function healthState(data)
    if not data or not data.online then return "FAULT" end

    if data.prc.state == "UNKNOWN" or data.prc.state == "WARN" then
        return "WARN"
    end

    if data.output.mixed then
        return "WARN"
    end

    return "OK"
end

local function buildModuleStatus(data)
    local state = moduleState(data)
    local health = healthState(data)
    local outputFill = data.outputFill

    local alarms = {}
    if data.output.mixed then
        table.insert(alarms, "OUTPUT BUFFER MIXED")
    end
    if data.prc.state == "UNKNOWN" or data.prc.state == "WARN" then
        table.insert(alarms, "PRC CONTROL STATE")
    end

    return {
        contract=1,
        id=config.status.id,
        label=config.status.label,
        type=config.status.type,
        version=PROGRAM_VERSION,

        mode=operatingMode,
        state=state,
        health=health,
        runtimeState=
            health == "FAULT" and "FAULT"
            or (state == "RUN" and "ACTIVE")
            or (operatingMode == "AUTO" and autoState.sleepHold and "SLEEP")
            or "IDLE",

        runtime={
            activeSeconds=config.runtime.activeSeconds,
            idleSeconds=config.runtime.idleSeconds,
            sleepSeconds=config.runtime.sleepSeconds,
            lastPoll=runtimeState.lastPoll,
        },

        reason=operatingMode == "AUTO" and autoState.reason or "MANUAL",

        metrics={
            hdpe=outputFill,
            liquidEthene=data.prc.liquidEtheneFill,
            oxygen=data.prc.oxygenFill,
        },

        ui={
            prcName=config.prc,
            prcState=data.prc.state,

            substrateReadable=data.prc.substrateReadable,
            substrateCount=data.prc.substrateCount,
            substrateName=data.prc.substrateName,

            liquidEtheneReadable=data.prc.liquidEtheneReadable,
            liquidEtheneFill=data.prc.liquidEtheneFill,

            oxygenReadable=data.prc.oxygenReadable,
            oxygenFill=data.prc.oxygenFill,

            energy=data.prc.energy,
            maxEnergy=data.prc.maxEnergy,
            energyUsage=data.prc.energyUsage,

            outputItem=data.output.itemName,
            outputCount=data.output.count,
            outputCapacity=config.outputCapacity,
            outputFill=outputFill,

            outputStop=config.auto.outputStop,
            outputResume=config.auto.outputResume,
        },

        details={
            {
                label="HDPE",
                value=type(outputFill) == "number"
                    and ("%.1f%%"):format(outputFill * 100)
                    or "N/A",
            },
            {
                label="SUBSTRATE",
                value=data.prc.substrateReadable
                    and tostring(data.prc.substrateCount or 0)
                    or "N/A",
            },
            {
                label="LIQ ETHENE",
                value=type(data.prc.liquidEtheneFill) == "number"
                    and ("%.1f%%"):format(data.prc.liquidEtheneFill * 100)
                    or "N/A",
            },
            {
                label="O2",
                value=type(data.prc.oxygenFill) == "number"
                    and ("%.1f%%"):format(data.prc.oxygenFill * 100)
                    or "N/A",
            },
        },

        alarms=alarms,
    }
end

local function loadStatusBus()
    if not fs.exists(STATUS_BUS_PATH) then return nil end
    local ok, bus = pcall(dofile, STATUS_BUS_PATH)
    if not ok or type(bus) ~= "table" then return nil end
    pcall(bus.open)
    return bus
end

local function publishImmediateStatus()
    local bus = loadStatusBus()
    if bus and dataCache then
        pcall(bus.broadcastStatus, buildModuleStatus(dataCache))
    end
end

local function statusLoop()
    local bus = loadStatusBus()

    while true do
        if not bus then bus = loadStatusBus() end

        if bus and dataCache then
            pcall(bus.broadcastStatus, buildModuleStatus(dataCache))
        end

        sleep(config.status.publishSeconds)
    end
end

local function computeRuntimeState(data)
    if not data or not data.online then return "FAULT" end
    if moduleState(data) == "RUN" then return "ACTIVE" end

    if operatingMode == "AUTO" and autoState.sleepHold then
        return "SLEEP"
    end

    return "IDLE"
end

local function pollInterval()
    local state = computeRuntimeState(dataCache)
    runtimeState.state = state

    if state == "SLEEP" then return config.runtime.sleepSeconds end
    if state == "IDLE" then return config.runtime.idleSeconds end
    return config.runtime.activeSeconds
end

local function waitForNextPoll(seconds)
    local timer = os.startTimer(math.max(0.1, seconds))

    while true do
        local event, p1, p2 = os.pullEvent()

        if event == "timer" and p1 == timer then
            return
        elseif event == "factory_module_wake" and p1 == "hdpe" then
            runtimeState.wakeReason = tostring(p2 or "WAKE")
            return
        end
    end
end

local function dataLoop()
    while true do
        local ok, fresh = pcall(collectData)

        if ok then
            dataCache = fresh
            runtimeState.lastPoll = os.epoch("utc") / 1000

            if operatingMode == "AUTO" then
                pcall(applyAuto, dataCache)

                local refreshOK, after = pcall(collectData)
                if refreshOK then dataCache = after end
            end

            publishImmediateStatus()
        end

        waitForNextPoll(pollInterval())
    end
end

local function controlLoop()
    while true do
        local _, action, targetMode = os.pullEvent("factory_hdpe_control")

        if action == "toggle_mode" then
            operatingMode = operatingMode == "AUTO" and "MANUAL" or "AUTO"
            autoState.sleepHold = false

            if operatingMode == "AUTO" then
                autoState.outputHold = nil
                autoState.reason = "AUTO INIT"
            else
                autoState.outputHold = false
                autoState.reason = "MANUAL"
            end

        elseif operatingMode == "MANUAL" and action == "prc" then
            setPrcMode(targetMode)
        end

        local ok, fresh = pcall(collectData)
        if ok then dataCache = fresh end

        if operatingMode == "AUTO" and dataCache then
            pcall(applyAuto, dataCache)
            local refreshOK, after = pcall(collectData)
            if refreshOK then dataCache = after end
        end

        publishImmediateStatus()
        os.queueEvent("factory_module_wake", "hdpe", "CONTROL")
    end
end

parallel.waitForAny(dataLoop, statusLoop, controlLoop)
