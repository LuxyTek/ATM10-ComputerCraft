local PROGRAM_VERSION = "0.2.0"
local STATUS_BUS_PATH = "/programs/factory/lib/status_bus.lua"
local CONFIG_PATH = "/config/factory_sulfuric_acid.lua"

local defaults = {
    stopMode = "HIGH",
    sulfurDioxideTank = "ultimateMaxChemicalTank_3",
    waterVaporTank = "ultimateMaxChemicalTank_4",
    sulfurTrioxideTank = "ultimateMaxChemicalTank_5",
    sulfuricAcidTank = "ultimateMaxChemicalTank_6",
    oxidizers = {
        "chemicalOxidizer_0",
        "chemicalOxidizer_1",
    },
    sulfurTrioxideInfuser = "chemicalInfuser_1",
    sulfuricAcidInfuser = "chemicalInfuser_2",

    -- Optional: fill this list once the Water Vapor pump / Condensentrator
    -- peripheral names are known. Until then the chain toggle is logical only.
    waterVaporMachines = {},
    auto = {
        outputStop = 0.95,
        outputResume = 0.80,
        inputStop = 0.10,
        inputResume = 0.20,
    },
    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },
    status = {
        publishSeconds = 2,
        id = "sulfuric",
        label = "SULFURIC ACID",
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
local oxygenTankRoleCache = {}

local runtimeState = {
    state = "ACTIVE",
    wakeReason = "BOOT",
    lastPoll = 0,
}

local chainEnabled = {
    so2 = true,
    so3 = true,
    vapor = true,
    acid = true,
}

local autoState = {
    so2Hold = nil,
    so3Hold = nil,
    acidHold = nil,
    so2InputHold = false,
    oxygenHold = false,
    so3InputHold = false,
    vaporHold = false,
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
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then return nil end
    return math.max(0, math.min(1, value / maximum))
end

local function stateFromMode(mode)
    if mode == "DISABLED" then return "RUN" end
    if mode == config.stopMode then return "STOP" end
    if mode == nil then return "UNKNOWN" end
    return "WARN"
end

local function readChemicalTank(name)
    if not peripheral.isPresent(name) then
        return { present=false, amount=0, capacity=0, fill=nil, name=nil }
    end
    local dev = peripheral.wrap(name)
    local stored = safeCall(dev, "getStored")
    local capacity = tonumber(safeCall(dev, "getCapacity")) or 0
    local amount = type(stored) == "table" and (tonumber(stored.amount) or 0) or 0
    return {
        present=true,
        amount=amount,
        capacity=capacity,
        fill=ratio(amount, capacity),
        name=type(stored) == "table" and stored.name or nil,
    }
end

local function readMachine(name, kind)
    if not peripheral.isPresent(name) then
        return { present=false, name=name, kind=kind, state="ABSENT" }
    end
    local dev = peripheral.wrap(name)
    return {
        present=true,
        name=name,
        kind=kind,
        state=stateFromMode(safeCall(dev, "getRedstoneMode")),
        energy=safeCall(dev, "getEnergy"),
        maxEnergy=safeCall(dev, "getMaxEnergy"),
        energyUsage=safeCall(dev, "getEnergyUsage"),
    }
end

local function findOxygen()
    local amount, capacity, count = 0, 0, 0
    for _, name in ipairs(peripheral.getNames()) do
        local pType = tostring(peripheral.getType(name) or ""):lower()
        if pType:find("chemicaltank", 1, true) then
            local dev = peripheral.wrap(name)
            local stored = safeCall(dev, "getStored")
            local chemical = type(stored) == "table" and stored.name or nil
            if chemical == "mekanism:oxygen" then
                oxygenTankRoleCache[name] = true
            elseif chemical ~= nil then
                oxygenTankRoleCache[name] = nil
            end
            if oxygenTankRoleCache[name] then
                amount = amount + (type(stored) == "table" and (tonumber(stored.amount) or 0) or 0)
                capacity = capacity + (tonumber(safeCall(dev, "getCapacity")) or 0)
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

local function setMachineMode(name, targetMode)
    if not peripheral.isPresent(name) then return false end
    local dev = peripheral.wrap(name)
    if not dev or type(dev.setRedstoneMode) ~= "function" then return false end
    return pcall(dev.setRedstoneMode, targetMode)
end

local function setOxidizersMode(targetMode)
    local ok = true
    for _, name in ipairs(config.oxidizers) do
        if not setMachineMode(name, targetMode) then ok = false end
    end
    return ok
end

local function setWaterVaporMode(targetMode)
    local names = type(config.waterVaporMachines) == "table"
        and config.waterVaporMachines
        or {}

    if #names == 0 then return false end

    local ok = true
    for _, name in ipairs(names) do
        if not setMachineMode(name, targetMode) then ok = false end
    end
    return ok
end

local function setChainMode(chainId, targetMode)
    if chainId == "so2" then
        return setOxidizersMode(targetMode)
    elseif chainId == "so3" then
        return setMachineMode(config.sulfurTrioxideInfuser, targetMode)
    elseif chainId == "vapor" then
        return setWaterVaporMode(targetMode)
    elseif chainId == "acid" then
        return setMachineMode(config.sulfuricAcidInfuser, targetMode)
    end
    return false
end

local function setAllMode(targetMode)
    local ok = setOxidizersMode(targetMode)
    if not setMachineMode(config.sulfurTrioxideInfuser, targetMode) then ok = false end
    if not setMachineMode(config.sulfuricAcidInfuser, targetMode) then ok = false end

    -- Water Vapor remains optional until its peripheral mapping is known.
    if type(config.waterVaporMachines) == "table"
        and #config.waterVaporMachines > 0
        and not setWaterVaporMode(targetMode) then
        ok = false
    end

    return ok
end

local function collectData()
    local oxidizers = {}
    local machinesPresent = true
    for _, name in ipairs(config.oxidizers) do
        local machine = readMachine(name, "OXIDIZER")
        table.insert(oxidizers, machine)
        if not machine.present then machinesPresent = false end
    end

    local so3Infuser = readMachine(config.sulfurTrioxideInfuser, "SO3 INFUSER")
    local acidInfuser = readMachine(config.sulfuricAcidInfuser, "H2SO4 INFUSER")
    local so2 = readChemicalTank(config.sulfurDioxideTank)
    local so3 = readChemicalTank(config.sulfurTrioxideTank)
    local vapor = readChemicalTank(config.waterVaporTank)
    local acid = readChemicalTank(config.sulfuricAcidTank)
    local oxygen = findOxygen()

    return {
        oxidizers=oxidizers,
        so3Infuser=so3Infuser,
        acidInfuser=acidInfuser,
        so2=so2,
        so3=so3,
        vapor=vapor,
        acid=acid,
        oxygen=oxygen,
        online=machinesPresent
            and so3Infuser.present
            and acidInfuser.present
            and so2.present
            and so3.present
            and vapor.present
            and acid.present,
    }
end

local function updateOutputHold(current, fill, stoppedPhysically)
    if current == nil then
        current = stoppedPhysically
            and type(fill) == "number"
            and fill > config.auto.outputResume
    end
    if current then
        if type(fill) == "number" and fill <= config.auto.outputResume then current = false end
    elseif type(fill) == "number" and fill >= config.auto.outputStop then
        current = true
    end
    return current
end

local function updateInputHold(current, fill)
    if type(fill) ~= "number" then return current end
    if current then
        if fill >= config.auto.inputResume then current = false end
    elseif fill <= config.auto.inputStop then
        current = true
    end
    return current
end

local function anyRunning(list)
    for _, machine in ipairs(list or {}) do
        if machine.state == "RUN" then return true end
    end
    return false
end

local function applyAuto(data)
    if operatingMode ~= "AUTO" then return end
    autoState.sleepHold = false

    if not data.online then
        autoState.reason = "FAULT PERIPHERAL"
        setAllMode(config.stopMode)
        return
    end

    autoState.so2Hold = updateOutputHold(
        autoState.so2Hold,
        data.so2.fill,
        not anyRunning(data.oxidizers)
    )
    autoState.so3Hold = updateOutputHold(
        autoState.so3Hold,
        data.so3.fill,
        data.so3Infuser.state == "STOP"
    )
    autoState.acidHold = updateOutputHold(
        autoState.acidHold,
        data.acid.fill,
        data.acidInfuser.state == "STOP"
    )

    autoState.so2InputHold = updateInputHold(autoState.so2InputHold, data.so2.fill)
    autoState.oxygenHold = updateInputHold(autoState.oxygenHold, data.oxygen.fill)
    autoState.so3InputHold = updateInputHold(autoState.so3InputHold, data.so3.fill)
    autoState.vaporHold = updateInputHold(autoState.vaporHold, data.vapor.fill)

    local so2CanRun =
        chainEnabled.so2
        and not autoState.so2Hold

    setOxidizersMode(so2CanRun and "DISABLED" or config.stopMode)

    local so3CanRun =
        chainEnabled.so3
        and not autoState.so3Hold
        and not autoState.so2InputHold
        and not autoState.oxygenHold

    setMachineMode(
        config.sulfurTrioxideInfuser,
        so3CanRun and "DISABLED" or config.stopMode
    )

    -- If physical Water Vapor machines are mapped later, this becomes a real
    -- machine control. With no mapping, the toggle remains a logical gate.
    if type(config.waterVaporMachines) == "table"
        and #config.waterVaporMachines > 0 then
        setWaterVaporMode(
            chainEnabled.vapor and "DISABLED" or config.stopMode
        )
    end

    local acidCanRun =
        chainEnabled.acid
        and chainEnabled.vapor
        and not autoState.acidHold
        and not autoState.so3InputHold
        and not autoState.vaporHold

    setMachineMode(
        config.sulfuricAcidInfuser,
        acidCanRun and "DISABLED" or config.stopMode
    )

    local reasons = {}

    if not chainEnabled.so2 then
        table.insert(reasons, "SULFUR DIOXIDE DISABLED")
    elseif autoState.so2Hold then
        table.insert(reasons, "SULFUR DIOXIDE FULL")
    end

    if not chainEnabled.so3 then
        table.insert(reasons, "SULFUR TRIOXIDE DISABLED")
    elseif autoState.so3Hold then
        table.insert(reasons, "SULFUR TRIOXIDE FULL")
    elseif autoState.so2InputHold then
        table.insert(reasons, "SULFUR TRIOXIDE WAIT SULFUR DIOXIDE")
    elseif autoState.oxygenHold then
        table.insert(reasons, "SULFUR TRIOXIDE WAIT O2")
    end

    if not chainEnabled.vapor then
        table.insert(reasons, "WATER VAPOR DISABLED")
    end

    if not chainEnabled.acid then
        table.insert(reasons, "SULFURIC ACID DISABLED")
    elseif not chainEnabled.vapor then
        table.insert(reasons, "SULFURIC ACID HOLD WATER VAPOR OFF")
    elseif autoState.acidHold then
        table.insert(reasons, "SULFURIC ACID FULL")
    elseif autoState.so3InputHold then
        table.insert(reasons, "SULFURIC ACID WAIT SULFUR TRIOXIDE")
    elseif autoState.vaporHold then
        table.insert(reasons, "SULFURIC ACID WAIT WATER VAPOR")
    end

    autoState.reason = #reasons == 0
        and "PRODUCTION"
        or table.concat(reasons, " | ")

    autoState.sleepHold =
        (not chainEnabled.so2 or autoState.so2Hold == true)
        and (not chainEnabled.so3 or autoState.so3Hold == true)
        and (not chainEnabled.acid or autoState.acidHold == true or not chainEnabled.vapor)
end

local function moduleState(data)
    if not data or not data.online then return "STOP" end
    if anyRunning(data.oxidizers)
        or data.so3Infuser.state == "RUN"
        or data.acidInfuser.state == "RUN" then
        return "RUN"
    end
    if operatingMode == "AUTO" then return "HOLD" end
    return "STOP"
end

local function healthState(data)
    if not data or not data.online then return "FAULT" end
    for _, machine in ipairs(data.oxidizers) do
        if machine.state == "UNKNOWN" or machine.state == "WARN" then return "WARN" end
    end
    if data.so3Infuser.state == "UNKNOWN"
        or data.so3Infuser.state == "WARN"
        or data.acidInfuser.state == "UNKNOWN"
        or data.acidInfuser.state == "WARN"
        or not data.oxygen.present then
        return "WARN"
    end
    return "OK"
end

local function buildModuleStatus(data)
    local state = moduleState(data)
    local health = healthState(data)
    local machines = {}
    for _, machine in ipairs(data.oxidizers) do table.insert(machines, machine) end
    table.insert(machines, data.so3Infuser)
    table.insert(machines, data.acidInfuser)

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
            sulfurDioxide=data.so2.fill,
            sulfurTrioxide=data.so3.fill,
            waterVapor=data.vapor.fill,
            sulfuricAcid=data.acid.fill,
            oxygen=data.oxygen.fill,
        },
        ui={
            sulfurDioxideFill=data.so2.fill,
            sulfurDioxideAmount=data.so2.amount,
            sulfurDioxideCapacity=data.so2.capacity,
            sulfurTrioxideFill=data.so3.fill,
            sulfurTrioxideAmount=data.so3.amount,
            sulfurTrioxideCapacity=data.so3.capacity,
            waterVaporFill=data.vapor.fill,
            waterVaporAmount=data.vapor.amount,
            waterVaporCapacity=data.vapor.capacity,
            sulfuricAcidFill=data.acid.fill,
            sulfuricAcidAmount=data.acid.amount,
            sulfuricAcidCapacity=data.acid.capacity,
            oxygenFill=data.oxygen.fill,
            oxygenAmount=data.oxygen.amount,
            oxygenCapacity=data.oxygen.capacity,
            oxygenTankCount=data.oxygen.count,
            so2Enabled=chainEnabled.so2,
            so3Enabled=chainEnabled.so3,
            vaporEnabled=chainEnabled.vapor,
            acidEnabled=chainEnabled.acid,
            vaporPhysicalControl=
                type(config.waterVaporMachines) == "table"
                and #config.waterVaporMachines > 0,

            so2Stage=not chainEnabled.so2 and "DISABLED"
                or autoState.so2Hold and "HOLD FULL"
                or "RUN",
            so3Stage=not chainEnabled.so3 and "DISABLED"
                or autoState.so3Hold and "HOLD FULL"
                or autoState.so2InputHold and "HOLD SULFUR DIOXIDE"
                or autoState.oxygenHold and "HOLD O2"
                or "RUN",
            vaporStage=not chainEnabled.vapor and "DISABLED"
                or (
                    type(config.waterVaporMachines) == "table"
                    and #config.waterVaporMachines > 0
                    and "RUN"
                    or "BUFFER ONLY"
                ),
            acidStage=not chainEnabled.acid and "DISABLED"
                or not chainEnabled.vapor and "HOLD VAPOR OFF"
                or autoState.acidHold and "HOLD FULL"
                or autoState.so3InputHold and "HOLD SULFUR TRIOXIDE"
                or autoState.vaporHold and "HOLD VAPOR"
                or "RUN",
            machines=machines,
            outputStop=config.auto.outputStop,
            outputResume=config.auto.outputResume,
            inputStop=config.auto.inputStop,
            inputResume=config.auto.inputResume,
        },
        details={
            {label="SULFUR DIOXIDE", value=type(data.so2.fill)=="number" and ("%.1f%%"):format(data.so2.fill*100) or "N/A"},
            {label="SULFUR TRIOXIDE", value=type(data.so3.fill)=="number" and ("%.1f%%"):format(data.so3.fill*100) or "N/A"},
            {label="WATER VAPOR", value=type(data.vapor.fill)=="number" and ("%.1f%%"):format(data.vapor.fill*100) or "N/A"},
            {label="SULFURIC ACID", value=type(data.acid.fill)=="number" and ("%.1f%%"):format(data.acid.fill*100) or "N/A"},
            {label="O2 SOURCE", value=type(data.oxygen.fill)=="number" and ("%.1f%%"):format(data.oxygen.fill*100) or "N/A"},
        },
        alarms=health == "WARN" and {"SOURCE OR MACHINE WARNING"} or {},
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
    if bus and dataCache then pcall(bus.broadcastStatus, buildModuleStatus(dataCache)) end
end

local function statusLoop()
    local bus = loadStatusBus()
    while true do
        if not bus then bus = loadStatusBus() end
        if bus and dataCache then pcall(bus.broadcastStatus, buildModuleStatus(dataCache)) end
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
        elseif event == "factory_module_wake" and p1 == "sulfuric" then
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
        local _, action, arg1, arg2 = os.pullEvent("factory_sulfuric_control")

        if action == "toggle_mode" then
            operatingMode = operatingMode == "AUTO" and "MANUAL" or "AUTO"
            autoState.sleepHold = false

            if operatingMode == "AUTO" then
                autoState.so2Hold = nil
                autoState.so3Hold = nil
                autoState.acidHold = nil
                autoState.reason = "AUTO INIT"
            else
                autoState.reason = "MANUAL"
            end

        elseif action == "chain" and chainEnabled[arg1] ~= nil then
            local enabled = arg2 == true
            chainEnabled[arg1] = enabled

            if not enabled then
                setChainMode(arg1, config.stopMode)
            elseif operatingMode == "MANUAL" then
                setChainMode(arg1, "DISABLED")
            end

        elseif operatingMode == "MANUAL" and action == "all" then
            setAllMode(arg1)
        end

        local ok, fresh = pcall(collectData)
        if ok then dataCache = fresh end

        if operatingMode == "AUTO" and dataCache then
            pcall(applyAuto, dataCache)
            local refreshOK, after = pcall(collectData)
            if refreshOK then dataCache = after end
        end

        publishImmediateStatus()
        os.queueEvent("factory_module_wake", "sulfuric", "CONTROL")
    end
end

parallel.waitForAny(dataLoop, statusLoop, controlLoop)
