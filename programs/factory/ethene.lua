local PROGRAM_VERSION = "0.3.1"
local STATUS_BUS_PATH = "/programs/factory/lib/status_bus.lua"

local defaults = {
    stopMode = "HIGH",

    biofuelBarrel = "sophisticatedstorage:barrel_1",
    biofuelCapacity = 270336,
    etheneTank = "ultimateMaxChemicalTank_2",
    condensentrator = "rotaryCondensentrator_0",
    liquidEtheneTank = "ultimateFluidTank_7",

    lines = {
        {
            id = "LINE 1",
            waterTank = "ultimateFluidTank_5",
            pump = "electricPump_4",
            prc = "pressurizedReactionChamber_2",
        },
        {
            id = "LINE 2",
            waterTank = "ultimateFluidTank_6",
            pump = "electricPump_3",
            prc = "pressurizedReactionChamber_3",
        },
    },

    auto = {
        etheneStop = 0.95,
        etheneResume = 0.80,
        scaleToTwo = 0.30,

        liquidStop = 0.95,
        liquidResume = 0.80,

        waterStop = 0.10,
        waterResume = 0.40,

        hydrogenStop = 0.10,
        hydrogenResume = 0.20,

        substrateWarn = 48,
        substrateStop = 64,
    },

    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },

    status = {
        publishSeconds = 2,
        id = "ethene",
        label = "ETHENE",
        type = "process",
    },
}

local CONFIG_PATH = "/config/factory_ethene.lua"

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
local hydrogenTankRoleCache = {}

local operatingMode = "AUTO"
local dataCache = nil
local runtimeState = {
    state = "ACTIVE",
    wakeReason = "BOOT",
    lastPoll = 0,
}

local autoState = {
    hold = false,
    sleepHold = false,
    hydrogenHold = false,
    liquidHold = nil,
    waterHold = {},
    targetLines = 0,
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

local function summarizeInventory(name)
    if not peripheral.isPresent(name) then
        return { present=false, readable=false, count=0 }
    end

    local dev = peripheral.wrap(name)
    local items = safeCall(dev, "list")
    if type(items) ~= "table" then
        return { present=true, readable=false, count=0 }
    end

    local total = 0
    local dominantName = nil
    local dominantCount = -1

    for _, item in pairs(items) do
        if type(item) == "table" then
            local count = tonumber(item.count) or 0
            total = total + count
            if count > dominantCount then
                dominantCount = count
                dominantName = item.name
            end
        end
    end

    return {
        present=true,
        readable=true,
        count=total,
        itemName=dominantName,
    }
end

local function readChemicalTank(name)
    if not peripheral.isPresent(name) then
        return { present=false, amount=0, capacity=0, fill=nil }
    end

    local dev = peripheral.wrap(name)
    local stored = safeCall(dev, "getStored")
    local capacity = safeCall(dev, "getCapacity")
    local amount = type(stored) == "table" and tonumber(stored.amount) or 0

    return {
        present=true,
        name=type(stored) == "table" and stored.name or nil,
        amount=amount or 0,
        capacity=tonumber(capacity) or 0,
        fill=ratio(amount or 0, tonumber(capacity) or 0),
    }
end

local function readWaterTank(name)
    if not peripheral.isPresent(name) then
        return { present=false, amount=0, capacity=0, fill=nil }
    end

    local dev = peripheral.wrap(name)
    local stored = safeCall(dev, "getStored")
    local capacity = safeCall(dev, "getCapacity")
    local amount = type(stored) == "table" and tonumber(stored.amount) or 0

    return {
        present=true,
        amount=amount or 0,
        capacity=tonumber(capacity) or 0,
        fill=ratio(amount or 0, tonumber(capacity) or 0),
        fluid=type(stored) == "table" and stored.name or nil,
    }
end

local function readFluidTank(name)
    if not peripheral.isPresent(name) then
        return { present=false, amount=0, capacity=0, fill=nil }
    end

    local dev = peripheral.wrap(name)
    local stored = safeCall(dev, "getStored")
    local capacity = safeCall(dev, "getCapacity")
    local amount = type(stored) == "table" and tonumber(stored.amount) or 0

    return {
        present=true,
        name=type(stored) == "table" and stored.name or nil,
        amount=amount or 0,
        capacity=tonumber(capacity) or 0,
        fill=ratio(amount or 0, tonumber(capacity) or 0),
    }
end

local function firstCall(device, methods)
    for _, method in ipairs(methods) do
        local value = safeCall(device, method)
        if value ~= nil then return value end
    end
    return nil
end

local function readCondensentrator(name)
    if not peripheral.isPresent(name) then
        return { present=false, state="ABSENT" }
    end

    local dev = peripheral.wrap(name)
    local state = stateFromMode(safeCall(dev, "getRedstoneMode"))

    return {
        present=true,
        state=state,
        input=firstCall(dev, {"getInput", "getInputGas"}),
        output=firstCall(dev, {"getOutput", "getOutputFluid"}),
        inputFill=firstCall(dev, {"getInputFilledPercentage", "getInputGasFilledPercentage"}),
        outputFill=firstCall(dev, {"getOutputFilledPercentage", "getOutputFluidFilledPercentage"}),
        energy=safeCall(dev, "getEnergy"),
        maxEnergy=safeCall(dev, "getMaxEnergy"),
        energyUsage=safeCall(dev, "getEnergyUsage"),
    }
end

local function findHydrogen()
    local amount, capacity = 0, 0
    local count = 0

    for _, name in ipairs(peripheral.getNames()) do
        local pType = tostring(peripheral.getType(name) or ""):lower()
        if pType:find("chemicaltank", 1, true) then
            local dev = peripheral.wrap(name)
            local stored = safeCall(dev, "getStored")
            local chemical = type(stored) == "table" and stored.name or nil

            if chemical == "mekanism:hydrogen" then
                hydrogenTankRoleCache[name] = true
            elseif chemical ~= nil then
                hydrogenTankRoleCache[name] = nil
            end

            if hydrogenTankRoleCache[name] then
                local cap = tonumber(safeCall(dev, "getCapacity")) or 0
                amount = amount + (type(stored) == "table" and (tonumber(stored.amount) or 0) or 0)
                capacity = capacity + cap
                count = count + 1
            end
        end
    end

    return {
        present=count > 0,
        count=count,
        amount=amount,
        capacity=capacity,
        fill=ratio(amount, capacity),
    }
end

local function readLine(lineCfg)
    local water = readWaterTank(lineCfg.waterTank)

    local pumpPresent = peripheral.isPresent(lineCfg.pump)
    local pump = pumpPresent and peripheral.wrap(lineCfg.pump) or nil
    local pumpState = pumpPresent and stateFromMode(safeCall(pump, "getRedstoneMode")) or "ABSENT"

    local prcPresent = peripheral.isPresent(lineCfg.prc)
    local prc = prcPresent and peripheral.wrap(lineCfg.prc) or nil
    local prcState = prcPresent and stateFromMode(safeCall(prc, "getRedstoneMode")) or "ABSENT"

    local outputItem = safeCall(prc, "getOutputItem")
    local substrateCount = 0
    if type(outputItem) == "table" and outputItem.name == "mekanism:substrate" then
        substrateCount = tonumber(outputItem.count) or 0
    end

    local state
    if not water.present or not pumpPresent or not prcPresent then
        state = "MISSING"
    elseif pumpState == "RUN" and prcState == "RUN" then
        state = "RUN"
    elseif pumpState == "STOP" and prcState == "STOP" then
        state = "STOP"
    else
        state = "MIXED"
    end

    return {
        id=lineCfg.id,
        waterTank=lineCfg.waterTank,
        pump=lineCfg.pump,
        prc=lineCfg.prc,
        water=water,
        pumpPresent=pumpPresent,
        prcPresent=prcPresent,
        pumpState=pumpState,
        prcState=prcState,
        state=state,
        substrateCount=substrateCount,

        pumpFluidFill=safeCall(pump, "getFluidFilledPercentage"),
        pumpEnergy=safeCall(pump, "getEnergy"),
        pumpMaxEnergy=safeCall(pump, "getMaxEnergy"),
        pumpEnergyUsage=safeCall(pump, "getEnergyUsage"),

        inputItem=safeCall(prc, "getInputItem"),
        inputGasFill=safeCall(prc, "getInputGasFilledPercentage"),
        outputGasFill=safeCall(prc, "getOutputGasFilledPercentage"),
        energy=safeCall(prc, "getEnergy"),
        maxEnergy=safeCall(prc, "getMaxEnergy"),
        energyUsage=safeCall(prc, "getEnergyUsage"),
    }
end

local function collectData()
    local lines = {}
    local criticalPresent = true

    for _, lineCfg in ipairs(config.lines) do
        local line = readLine(lineCfg)
        table.insert(lines, line)

        if not line.water.present or not line.pumpPresent or not line.prcPresent then
            criticalPresent = false
        end
    end

    local biofuel = summarizeInventory(config.biofuelBarrel)
    local ethene = readChemicalTank(config.etheneTank)
    local hydrogen = findHydrogen()
    local condensentrator = readCondensentrator(config.condensentrator)
    local liquidEthene = readFluidTank(config.liquidEtheneTank)

    if not biofuel.present
        or not ethene.present
        or not hydrogen.present
        or not condensentrator.present
        or not liquidEthene.present then
        criticalPresent = false
    end

    return {
        lines=lines,
        biofuel=biofuel,
        ethene=ethene,
        hydrogen=hydrogen,
        condensentrator=condensentrator,
        liquidEthene=liquidEthene,
        online=criticalPresent,
    }
end

local function setDeviceMode(name, targetMode)
    if not peripheral.isPresent(name) then return false end
    local dev = peripheral.wrap(name)
    if not dev or type(dev.setRedstoneMode) ~= "function" then return false end
    return pcall(dev.setRedstoneMode, targetMode)
end

local function setLineMode(lineCfg, targetMode)
    local pumpOK = setDeviceMode(lineCfg.pump, targetMode)
    local prcOK = setDeviceMode(lineCfg.prc, targetMode)
    return pumpOK and prcOK
end

local function setProductionMode(targetMode)
    local ok = true
    for _, lineCfg in ipairs(config.lines) do
        if not setLineMode(lineCfg, targetMode) then ok = false end
    end
    return ok
end

local function setAllMode(targetMode)
    local productionOK = setProductionMode(targetMode)
    local conversionOK = setDeviceMode(config.condensentrator, targetMode)
    return productionOK and conversionOK
end

local function updateWaterHolds(data)
    for _, line in ipairs(data.lines) do
        local fill = line.water.fill or 0
        local hold = autoState.waterHold[line.id] == true

        if hold then
            if fill >= config.auto.waterResume then
                autoState.waterHold[line.id] = false
            end
        elseif fill <= config.auto.waterStop then
            autoState.waterHold[line.id] = true
        end
    end
end

local function countSubstrate(data)
    local total = 0
    local maxStack = 0
    for _, line in ipairs(data.lines) do
        total = total + (line.substrateCount or 0)
        maxStack = math.max(maxStack, line.substrateCount or 0)
    end
    return total, maxStack
end

local function prcBiofuelCount(line)
    if type(line) ~= "table" or type(line.inputItem) ~= "table" then
        return 0
    end
    return math.max(0, tonumber(line.inputItem.count) or 0)
end

local function totalPrcBiofuel(data)
    local total = 0
    for _, line in ipairs(data.lines or {}) do
        total = total + prcBiofuelCount(line)
    end
    return total
end

local function applyAuto(data)
    if operatingMode ~= "AUTO" then return end

    autoState.sleepHold = false
    updateWaterHolds(data)

    if not data.online then
        autoState.hold = false
        autoState.targetLines = 0
        autoState.reason = "FAULT PERIPHERAL"
        setAllMode(config.stopMode)
        return
    end

    -- Conversion ETHENE GAS -> LIQUID ETHENE is regulated independently
    -- from the PRC production. This lets the condensentrator drain the gas
    -- buffer while the PRCs are temporarily held at 95%.
    local liquidFill = data.liquidEthene.fill or 0

    if autoState.liquidHold == nil then
        autoState.liquidHold =
            data.condensentrator.state == "STOP"
            and liquidFill > config.auto.liquidResume
    end

    if autoState.liquidHold then
        if liquidFill <= config.auto.liquidResume then
            autoState.liquidHold = false
        end
    elseif liquidFill >= config.auto.liquidStop then
        autoState.liquidHold = true
    end

    if autoState.liquidHold then
        if data.condensentrator.state ~= "STOP" then
            setDeviceMode(config.condensentrator, config.stopMode)
        end
    elseif data.condensentrator.state ~= "RUN" then
        setDeviceMode(config.condensentrator, "DISABLED")
    end

    local etheneFill = data.ethene.fill or 0

    if autoState.hold then
        if etheneFill <= config.auto.etheneResume then
            autoState.hold = false
        else
            -- Only enter deep sleep when both the PRC production and
            -- the liquid conversion are intentionally stopped.
            autoState.sleepHold = autoState.liquidHold == true
            autoState.targetLines = 0
            autoState.reason = ("BUFFER HOLD %.0f%%"):format(etheneFill * 100)
            setProductionMode(config.stopMode)
            return
        end
    elseif etheneFill >= config.auto.etheneStop then
        autoState.hold = true
        autoState.sleepHold = autoState.liquidHold == true
        autoState.targetLines = 0
        autoState.reason = ("BUFFER FULL %.0f%%"):format(etheneFill * 100)
        setProductionMode(config.stopMode)
        return
    end

    local biofuelBufferCount = tonumber(data.biofuel.count) or 0
    local biofuelBufferAvailable = biofuelBufferCount > 0
    local internalBiofuel = totalPrcBiofuel(data)

    -- The central Biofuel barrel may be empty while PRCs still contain fuel
    -- in their own input slots. Consume that local reserve before HOLD.
    if not biofuelBufferAvailable and internalBiofuel <= 0 then
        autoState.targetLines = 0
        autoState.reason = "HOLD BIOFUEL"
        setProductionMode(config.stopMode)
        return
    end

    local h2Fill = data.hydrogen.fill or 0
    if autoState.hydrogenHold then
        if h2Fill >= config.auto.hydrogenResume then
            autoState.hydrogenHold = false
        else
            autoState.targetLines = 0
            autoState.reason = ("HOLD H2 %.0f%%"):format(h2Fill * 100)
            setProductionMode(config.stopMode)
            return
        end
    elseif h2Fill <= config.auto.hydrogenStop then
        autoState.hydrogenHold = true
        autoState.targetLines = 0
        autoState.reason = ("HOLD H2 %.0f%%"):format(h2Fill * 100)
        setProductionMode(config.stopMode)
        return
    end

    local substrateTotal, substrateMax = countSubstrate(data)
    if substrateMax >= config.auto.substrateStop then
        autoState.targetLines = 0
        autoState.reason = "HOLD SUBSTRATE OUTPUT"
        setProductionMode(config.stopMode)
        return
    end

    local desired = etheneFill < config.auto.scaleToTwo and 2 or 1
    local running = 0

    for index, lineCfg in ipairs(config.lines) do
        local line = data.lines[index]
        local waterBlocked = autoState.waterHold[line.id] == true
        local lineHasBiofuel =
            biofuelBufferAvailable
            or prcBiofuelCount(line) > 0

        local enable = running < desired
            and lineHasBiofuel
            and not waterBlocked
            and line.water.present
            and line.pumpPresent
            and line.prcPresent

        if enable then
            setLineMode(lineCfg, "DISABLED")
            running = running + 1
        else
            setLineMode(lineCfg, config.stopMode)
        end
    end

    autoState.targetLines = running

    if running == 0 then
        autoState.reason = "HOLD WATER"
    elseif not biofuelBufferAvailable then
        autoState.reason = ("PRODUCTION %d/2 | BIOFUEL BUFFER EMPTY"):format(running)
    elseif substrateMax >= config.auto.substrateWarn then
        autoState.reason = ("PRODUCTION %d/2 | SUBSTRATE HIGH"):format(running)
    elseif autoState.liquidHold then
        autoState.reason = ("PRODUCTION %d/2 | LIQUID HOLD"):format(running)
    else
        autoState.reason = ("PRODUCTION %d/2"):format(running)
    end
end

local function moduleState(data)
    if not data or not data.online then return "STOP" end

    local conversionUsage =
        data.condensentrator and tonumber(data.condensentrator.energyUsage) or nil
    local conversionActive =
        conversionUsage ~= nil
        and conversionUsage > 0

    if conversionActive then
        return "RUN"
    end

    for _, line in ipairs(data.lines) do
        if line.state == "RUN" then return "RUN" end
    end

    if operatingMode == "AUTO" and (
        autoState.hold
        or autoState.reason:find("HOLD", 1, true)
        or autoState.reason:find("FAULT", 1, true)
    ) then
        return "HOLD"
    end

    return "STOP"
end

local function healthState(data)
    if not data or not data.online then return "FAULT" end

    local _, substrateMax = countSubstrate(data)
    if substrateMax >= config.auto.substrateWarn then
        return "WARN"
    end

    if data.condensentrator
        and (data.condensentrator.state == "UNKNOWN" or data.condensentrator.state == "WARN") then
        return "WARN"
    end

    return "OK"
end

local function buildModuleStatus(data)
    local state = moduleState(data)
    local health = healthState(data)
    local substrateTotal = countSubstrate(data)

    local lines = {}
    local machines = {}
    local activeLines = 0

    for _, line in ipairs(data.lines) do
        if line.state == "RUN" then activeLines = activeLines + 1 end
        table.insert(lines, {
            id=line.id,
            state=line.state,
            waterFill=line.water.fill,
            pumpState=line.pumpState,
            prcState=line.prcState,
            substrateCount=line.substrateCount,
            energy=line.energy,
            maxEnergy=line.maxEnergy,
            energyUsage=line.energyUsage,
        })

        table.insert(machines, {
            kind="PUMP",
            name=line.pump,
            lineId=line.id,
            state=line.pumpState,
            waterFill=line.water.fill,
            fluidFill=line.pumpFluidFill,
            energy=line.pumpEnergy,
            maxEnergy=line.pumpMaxEnergy,
            energyUsage=line.pumpEnergyUsage,
        })

        local inputName=nil
        local inputCount=nil
        if type(line.inputItem)=="table" then
            inputName=line.inputItem.name
            inputCount=line.inputItem.count
        end

        table.insert(machines, {
            kind="PRC",
            name=line.prc,
            lineId=line.id,
            state=line.prcState,
            waterFill=line.water.fill,
            hydrogenFill=line.inputGasFill,
            etheneFill=line.outputGasFill,
            substrateCount=line.substrateCount,
            inputItemName=inputName,
            inputItemCount=inputCount,
            energy=line.energy,
            maxEnergy=line.maxEnergy,
            energyUsage=line.energyUsage,
        })
    end

    table.insert(machines, {
        kind="CONDENS",
        name=config.condensentrator,
        lineId="CONVERSION",
        state=data.condensentrator.state,
        inputFill=data.condensentrator.inputFill or data.ethene.fill,
        outputFill=data.condensentrator.outputFill,
        liquidFill=data.liquidEthene.fill,
        hold=autoState.liquidHold == true,
        liquidName=data.liquidEthene.name,
        energy=data.condensentrator.energy,
        maxEnergy=data.condensentrator.maxEnergy,
        energyUsage=data.condensentrator.energyUsage,
    })

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
        activeLines=activeLines,
        totalLines=#config.lines,

        metrics={
            ethene=data.ethene.fill,
            liquidEthene=data.liquidEthene.fill,
            hydrogen=data.hydrogen.fill,
            biofuel=ratio(data.biofuel.count, config.biofuelCapacity),
        },

        ui={
            etheneFill=data.ethene.fill,
            etheneAmount=data.ethene.amount,
            etheneCapacity=data.ethene.capacity,

            liquidEtheneFill=data.liquidEthene.fill,
            liquidEtheneAmount=data.liquidEthene.amount,
            liquidEtheneCapacity=data.liquidEthene.capacity,
            liquidEtheneName=data.liquidEthene.name,
            conversionState=data.condensentrator.state,
            conversionHold=autoState.liquidHold == true,

            hydrogenFill=data.hydrogen.fill,
            hydrogenAmount=data.hydrogen.amount,
            hydrogenCapacity=data.hydrogen.capacity,

            biofuelCount=data.biofuel.count,
            biofuelCapacity=config.biofuelCapacity,
            biofuelFill=ratio(data.biofuel.count, config.biofuelCapacity),
            biofuelPrcReserve=totalPrcBiofuel(data),

            substrateTotal=substrateTotal,
            outputPath="QE",

            targetLines=autoState.targetLines,
            lines=lines,
            machines=machines,
        },

        details={
            {label="ETHENE GAS", value=type(data.ethene.fill)=="number" and ("%.1f%%"):format(data.ethene.fill*100) or "N/A"},
            {label="LIQ ETHENE", value=type(data.liquidEthene.fill)=="number" and ("%.1f%%"):format(data.liquidEthene.fill*100) or "N/A"},
            {label="H2", value=type(data.hydrogen.fill)=="number" and ("%.1f%%"):format(data.hydrogen.fill*100) or "N/A"},
            {label="BIOFUEL", value=tostring(data.biofuel.count or 0)},
            {label="SUBSTRATE", value=tostring(substrateTotal)},
        },

        alarms=health == "WARN" and {"SUBSTRATE OUTPUT HIGH"} or {},
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
    if operatingMode == "AUTO" and autoState.sleepHold then return "SLEEP" end
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
        elseif event == "factory_module_wake" and p1 == "ethene" then
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
        local _, action, target, targetMode = os.pullEvent("factory_ethene_control")

        if action == "toggle_mode" then
            operatingMode = operatingMode == "AUTO" and "MANUAL" or "AUTO"
            autoState.hold = false
            autoState.sleepHold = false
            if operatingMode == "AUTO" then
                autoState.liquidHold = nil
            else
                autoState.liquidHold = false
            end
            autoState.reason = operatingMode == "AUTO" and "AUTO INIT" or "MANUAL"

        elseif operatingMode == "MANUAL" and action == "all" then
            setAllMode(targetMode)

        elseif operatingMode == "MANUAL" and action == "line" then
            for _, lineCfg in ipairs(config.lines) do
                if lineCfg.id == target then
                    setLineMode(lineCfg, targetMode)
                    break
                end
            end

        elseif operatingMode == "MANUAL" and action == "machine" then
            setDeviceMode(target, targetMode)
        end

        local ok, fresh = pcall(collectData)
        if ok then dataCache = fresh end

        if operatingMode == "AUTO" and dataCache then
            pcall(applyAuto, dataCache)
            local refreshOK, after = pcall(collectData)
            if refreshOK then dataCache = after end
        end

        publishImmediateStatus()
        os.queueEvent("factory_module_wake", "ethene", "CONTROL")
    end
end

parallel.waitForAny(dataLoop, statusLoop, controlLoop)
