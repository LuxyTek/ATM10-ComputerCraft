local PROGRAM_VERSION = "0.9.3"
local args = { ... }
local HEADLESS = args[1] == "--headless"
local CONFIG_PATH = "/config/factory_h2o2.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"
local STATUS_BUS_PATH = "/programs/factory/lib/status_bus.lua"

local defaults = {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,
    stopMode = "HIGH",

    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },

    -- Mapping logique confirme sur l'installation actuelle.
    -- Il reste dans la configuration et n'est pas deduit des suffixes CC.
    lines = {
        { id = "LINE 1", pump = "electricPump_2", separator = "electrolyticSeparator_2" },
        { id = "LINE 2", pump = "electricPump_1", separator = "electrolyticSeparator_0" },
        { id = "LINE 3", pump = "electricPump_0", separator = "electrolyticSeparator_1" },
    },

    auto = {
        checkSeconds = 2,

        waterStop = 0.10,
        waterResume = 0.40,

        chemicalStop = 0.95,
        chemicalResume = 0.80,

        scaleToTwo = 0.30,
        scaleToOne = 0.70,
        stageHysteresis = 0.05,

        -- Evite qu'un gaz sature les buffers internes des Separators
        -- et bloque la production de l'autre gaz.
        -- Anti-blocage base sur les buffers INTERNES des Separators.
        -- Le dump commence avant saturation et reste actif jusqu'a
        -- evacuation suffisante du buffer interne.
        overflowEnable = 0.80,
        overflowDisable = 0.20,
    },

    status = {
        publishSeconds = 2,
        id = "h2o2",
        label = "H2/O2",
        type = "process",
    },
}

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return defaults end

    local ok, cfg = pcall(dofile, CONFIG_PATH)
    if not ok or type(cfg) ~= "table" then return defaults end

    local function mergeMissing(target, source)
        for key, value in pairs(source) do
            if target[key] == nil then
                target[key] = value
            elseif type(target[key]) == "table" and type(value) == "table" then
                mergeMissing(target[key], value)
            end
        end
    end

    mergeMissing(cfg, defaults)
    return cfg
end

local config = loadConfig()

local function getMonitor()
    if config.monitor and peripheral.isPresent(config.monitor) then
        return peripheral.wrap(config.monitor), config.monitor
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "monitor") then
            return peripheral.wrap(name), name
        end
    end

    error("Aucun monitor detecte")
end

local physicalMonitor = nil
local monitorName = nil
local width, height = 0, 0
local monitor = nil

if not HEADLESS then
    physicalMonitor, monitorName = getMonitor()
    physicalMonitor.setTextScale(config.textScale)
    width, height = physicalMonitor.getSize()
    monitor = window.create(physicalMonitor, 1, 1, width, height, false)
end

local currentPage = "overview"
local machinePage = 1

local tabOverviewBounds = nil
local tabMachinesBounds = nil
local updateBounds = nil
local modeButtonBounds = nil
local startBounds = nil
local stopBounds = nil
local prevBounds = nil
local nextBounds = nil
local machineButtonBounds = {}
local lineButtonBounds = {}

local updateConfirmUntil = 0
local updateMessage = nil
local updateMessageUntil = 0
local updateInProgress = false

local actionMessage = nil
local actionMessageUntil = 0
local controlPending = nil
local controlPendingSince = 0
local CONTROL_WATCHDOG_SECONDS = 5

local operatingMode = "AUTO"
local autoState = {
    targetLines = 0,
    reason = "INITIALISATION",
    stage = nil,
    waterHold = false,
    chemicalHold = nil,
    overflowHydrogen = false,
    overflowOxygen = false,
    surplusHydrogenHold = false,
    surplusOxygenHold = false,
    overflowFault = false,
    overflowError = nil,
    lastTick = 0,
}

local dataCache = nil
local publishImmediateStatus
local runtimeState = {
    state = "ACTIVE",
    wakeReason = "BOOT",
    lastPoll = 0,
}
local overflowResetPending = true
local separatorOutputMap = {}
local separatorDefaultMap = {}

local function safeCall(device, method, ...)
    if not device or type(device[method]) ~= "function" then return nil end

    local ok, result = pcall(device[method], ...)
    if ok then return result end

    return nil
end

local function normType(name)
    return tostring(peripheral.getType(name) or ""):lower()
end

local function controlStateFromMode(mode)
    if mode == "DISABLED" then return "RUN" end
    if mode == config.stopMode then return "STOP" end
    if mode == nil then return "UNKNOWN" end
    return tostring(mode)
end

local function classify()
    local found = {
        separators = {},
        pumps = {},
        waterTanks = {},
        hydrogenTanks = {},
        oxygenTanks = {},
        energyCubes = {},
    }

    local names = peripheral.getNames()
    table.sort(names)

    for _, name in ipairs(names) do
        local pType = normType(name)
        local device = peripheral.wrap(name)

        if pType:find("electrolyticseparator", 1, true) then
            table.insert(found.separators, {
                name = name,
                dev = device,
                state = controlStateFromMode(safeCall(device, "getRedstoneMode")),
            })

        elseif pType:find("electricpump", 1, true) then
            table.insert(found.pumps, {
                name = name,
                dev = device,
                state = controlStateFromMode(safeCall(device, "getRedstoneMode")),
            })

        elseif pType:find("energycube", 1, true) then
            table.insert(found.energyCubes, { name = name, dev = device })

        elseif pType:find("fluidtank", 1, true) then
            local stored = safeCall(device, "getStored")
            if type(stored) == "table" and stored.name == "minecraft:water" then
                table.insert(found.waterTanks, { name = name, dev = device })
            end

        elseif pType:find("chemicaltank", 1, true) then
            local stored = safeCall(device, "getStored")
            local chemical = type(stored) == "table" and stored.name or nil

            if chemical == "mekanism:hydrogen" then
                table.insert(found.hydrogenTanks, { name = name, dev = device })
            elseif chemical == "mekanism:oxygen" then
                table.insert(found.oxygenTanks, { name = name, dev = device })
            end
        end
    end

    return found
end

local function sumTanks(list)
    local amount, capacity = 0, 0

    for _, item in ipairs(list) do
        local stored = safeCall(item.dev, "getStored")
        local cap = safeCall(item.dev, "getCapacity")

        if type(stored) == "table" and type(stored.amount) == "number" then
            amount = amount + stored.amount
        end

        if type(cap) == "number" then
            capacity = capacity + cap
        end
    end

    return amount, capacity
end

local function sumSeparatorTelemetry(list)
    local energy, maxEnergy, usage = 0, 0, 0
    local responding, running = 0, 0

    for _, item in ipairs(list) do
        local currentEnergy = safeCall(item.dev, "getEnergy")
        local currentMax = safeCall(item.dev, "getMaxEnergy")
        local currentUsage = safeCall(item.dev, "getEnergyUsage")
        local input = safeCall(item.dev, "getInput")

        if type(currentEnergy) == "number" then energy = energy + currentEnergy end
        if type(currentMax) == "number" then maxEnergy = maxEnergy + currentMax end
        if type(currentUsage) == "number" then usage = usage + currentUsage end

        if input ~= nil then
            responding = responding + 1
        end

        if item.state == "RUN" then
            running = running + 1
        end
    end

    return energy, maxEnergy, usage, responding, running
end

local function getControlState(devices)
    local total = #devices.separators + #devices.pumps
    if total == 0 then return "UNKNOWN" end

    local running, stopped = 0, 0

    local function inspect(list)
        for _, item in ipairs(list) do
            if item.state == "RUN" then
                running = running + 1
            elseif item.state == "STOP" then
                stopped = stopped + 1
            end
        end
    end

    inspect(devices.separators)
    inspect(devices.pumps)

    if running == total then return "RUN" end
    if stopped == total then return "STOP" end

    return "MIXED"
end

local function collectData()
    local devices = classify()

    local water, waterCapacity = sumTanks(devices.waterTanks)
    local hydrogen, hydrogenCapacity = sumTanks(devices.hydrogenTanks)
    local oxygen, oxygenCapacity = sumTanks(devices.oxygenTanks)

    local energy, maxEnergy, usage, separatorResponding, separatorRunning =
        sumSeparatorTelemetry(devices.separators)

    local machines = {}

    for _, item in ipairs(devices.pumps) do
        table.insert(machines, {
            kind = "PUMP",
            name = item.name,
            state = item.state,
            fluidFill = safeCall(item.dev, "getFluidFilledPercentage"),
        })
    end

    for _, item in ipairs(devices.separators) do
        local left = safeCall(item.dev, "getLeftOutput")
        local right = safeCall(item.dev, "getRightOutput")
        local leftFill = safeCall(item.dev, "getLeftOutputFilledPercentage")
        local rightFill = safeCall(item.dev, "getRightOutputFilledPercentage")

        local leftChemical = type(left) == "table" and left.name or nil
        local rightChemical = type(right) == "table" and right.name or nil

        local mapping = separatorOutputMap[item.name] or {
            hydrogen = separatorDefaultMap.hydrogen,
            oxygen = separatorDefaultMap.oxygen,
        }

        if leftChemical == "mekanism:hydrogen" then
            mapping.hydrogen = "LEFT"
            mapping.oxygen = "RIGHT"
        elseif leftChemical == "mekanism:oxygen" then
            mapping.oxygen = "LEFT"
            mapping.hydrogen = "RIGHT"
        end

        if rightChemical == "mekanism:hydrogen" then
            mapping.hydrogen = "RIGHT"
            mapping.oxygen = "LEFT"
        elseif rightChemical == "mekanism:oxygen" then
            mapping.oxygen = "RIGHT"
            mapping.hydrogen = "LEFT"
        end

        if mapping.hydrogen and mapping.oxygen then
            separatorDefaultMap.hydrogen = mapping.hydrogen
            separatorDefaultMap.oxygen = mapping.oxygen
        end

        separatorOutputMap[item.name] = mapping

        local h2Fill = nil
        local o2Fill = nil

        if mapping.hydrogen == "LEFT" then h2Fill = leftFill end
        if mapping.hydrogen == "RIGHT" then h2Fill = rightFill end
        if mapping.oxygen == "LEFT" then o2Fill = leftFill end
        if mapping.oxygen == "RIGHT" then o2Fill = rightFill end

        table.insert(machines, {
            kind = "SEP",
            name = item.name,
            state = item.state,
            waterFill = safeCall(item.dev, "getInputFilledPercentage"),
            hydrogenFill = h2Fill,
            oxygenFill = o2Fill,
            hydrogenSide = mapping.hydrogen,
            oxygenSide = mapping.oxygen,
            leftFill = leftFill,
            rightFill = rightFill,
            leftChemical = leftChemical,
            rightChemical = rightChemical,
            leftDumpMode = safeCall(item.dev, "getLeftOutputDumpingMode"),
            rightDumpMode = safeCall(item.dev, "getRightOutputDumpingMode"),
        })
    end

    local lineOrder = {}
    for index, lineCfg in ipairs(config.lines or {}) do
        lineOrder[lineCfg.id] = index
    end

    local machineByName = {}
    for _, machine in ipairs(machines) do
        machineByName[machine.name] = machine
    end

    local lines = {}
    for _, lineCfg in ipairs(config.lines or {}) do
        local pump = machineByName[lineCfg.pump]
        local separator = machineByName[lineCfg.separator]

        if pump then pump.lineId = lineCfg.id end
        if separator then separator.lineId = lineCfg.id end

        local state
        if not pump or not separator then
            state = "MISSING"
        elseif pump.state == "RUN" and separator.state == "RUN" then
            state = "RUN"
        elseif pump.state == "STOP" and separator.state == "STOP" then
            state = "STOP"
        else
            state = "MIXED"
        end

        table.insert(lines, {
            id = lineCfg.id,
            state = state,
        })
    end

    table.sort(machines, function(a, b)
        local aOrder = a.lineId and lineOrder[a.lineId] or math.huge
        local bOrder = b.lineId and lineOrder[b.lineId] or math.huge

        if aOrder ~= bOrder then
            return aOrder < bOrder
        end

        if a.lineId ~= b.lineId then
            return tostring(a.lineId or "") < tostring(b.lineId or "")
        end

        local kindOrder = {
            PUMP = 1,
            SEP = 2,
        }

        local aKind = kindOrder[a.kind] or 99
        local bKind = kindOrder[b.kind] or 99

        if aKind ~= bKind then
            return aKind < bKind
        end

        return a.name < b.name
    end)

    return {
        devices = devices,
        machines = machines,
        lines = lines,

        water = water,
        waterCapacity = waterCapacity,

        hydrogen = hydrogen,
        hydrogenCapacity = hydrogenCapacity,

        oxygen = oxygen,
        oxygenCapacity = oxygenCapacity,

        energy = energy,
        maxEnergy = maxEnergy,
        usage = usage,

        separatorResponding = separatorResponding,
        separatorRunning = separatorRunning,
        controlState = getControlState(devices),
    }
end

local function setMachineMode(name, targetMode)
    if not peripheral.isPresent(name) then
        return false, "ABSENT"
    end

    local device = peripheral.wrap(name)

    if not device or type(device.setRedstoneMode) ~= "function" then
        return false, "NON CONTROLABLE"
    end

    local ok, err = pcall(device.setRedstoneMode, targetMode)

    if not ok then
        return false, tostring(err)
    end

    return true, name
end

local function setLineMode(lineId, targetMode)
    local lineCfg = nil

    for _, line in ipairs(config.lines or {}) do
        if line.id == lineId then
            lineCfg = line
            break
        end
    end

    if not lineCfg then
        return false, "LIGNE INCONNUE"
    end

    local pumpOK, sepOK = false, false

    if peripheral.isPresent(lineCfg.pump) then
        local pump = peripheral.wrap(lineCfg.pump)
        if pump and type(pump.setRedstoneMode) == "function" then
            pumpOK = pcall(pump.setRedstoneMode, targetMode)
        end
    end

    if peripheral.isPresent(lineCfg.separator) then
        local separator = peripheral.wrap(lineCfg.separator)
        if separator and type(separator.setRedstoneMode) == "function" then
            sepOK = pcall(separator.setRedstoneMode, targetMode)
        end
    end

    return pumpOK and sepOK,
        ("PUMP %s  SEP %s"):format(
            pumpOK and "OK" or "ERR",
            sepOK and "OK" or "ERR"
        )
end

local function setProcessMode(targetMode)
    local devices = dataCache and dataCache.devices or classify()

    local sepOK, pumpOK = 0, 0

    for _, item in ipairs(devices.separators) do
        if type(item.dev.setRedstoneMode) == "function" then
            local ok = pcall(item.dev.setRedstoneMode, targetMode)
            if ok then sepOK = sepOK + 1 end
        end
    end

    for _, item in ipairs(devices.pumps) do
        if type(item.dev.setRedstoneMode) == "function" then
            local ok = pcall(item.dev.setRedstoneMode, targetMode)
            if ok then pumpOK = pumpOK + 1 end
        end
    end

    local total = #devices.separators + #devices.pumps
    if total == 0 then
        return false, "AUCUNE MACHINE"
    end

    local allOK =
        sepOK == #devices.separators
        and pumpOK == #devices.pumps

    local detail = ("SEP %d/%d  PUMP %d/%d"):format(
        sepOK,
        #devices.separators,
        pumpOK,
        #devices.pumps
    )

    return allOK, detail
end

local function ratio(amount, capacity)
    if type(capacity) ~= "number" or capacity <= 0 then return 0 end
    return math.max(0, math.min(1, amount / capacity))
end

local function initialAutoStage(fill, maxLines)
    if maxLines <= 0 then return 0 end
    if fill >= config.auto.chemicalStop then return 0 end
    if fill >= config.auto.scaleToOne then return math.min(1, maxLines) end
    if fill >= config.auto.scaleToTwo then return math.min(2, maxLines) end
    return maxLines
end

local function decideAutoTarget(data)
    local maxLines = #(config.lines or {})
    if maxLines == 0 then
        autoState.stage = 0
        return 0, "NO LINES"
    end

    if data.waterCapacity <= 0 then
        autoState.stage = 0
        return 0, "FAULT WATER"
    end

    if data.hydrogenCapacity <= 0 or data.oxygenCapacity <= 0 then
        autoState.stage = 0
        return 0, "FAULT BUFFER"
    end

    local waterFill = ratio(data.water, data.waterCapacity)
    local h2Fill = ratio(data.hydrogen, data.hydrogenCapacity)
    local o2Fill = ratio(data.oxygen, data.oxygenCapacity)

    -- Les Quantum Entangloporters ne sont pas supervises.
    -- Les tanks locaux restent donc la reserve de reference :
    -- le moins rempli pilote la demande, et l'arret "plein"
    -- n'arrive que lorsque les DEUX tanks locaux sont pleins.
    local demandFill = math.min(h2Fill, o2Fill)
    local bothFull =
        h2Fill >= config.auto.chemicalStop
        and o2Fill >= config.auto.chemicalStop

    local bothRecovered =
        h2Fill <= config.auto.chemicalResume
        or o2Fill <= config.auto.chemicalResume

    if autoState.waterHold then
        if waterFill >= config.auto.waterResume then
            autoState.waterHold = false
            autoState.stage = nil
        else
            autoState.stage = 0
            return 0, ("HOLD WATER %.0f%%"):format(waterFill * 100)
        end
    elseif waterFill <= config.auto.waterStop then
        autoState.waterHold = true
        autoState.stage = 0
        return 0, ("HOLD WATER %.0f%%"):format(waterFill * 100)
    end

    if autoState.chemicalHold == nil then
        local processWasStopped = data.controlState == "STOP"
        autoState.chemicalHold =
            processWasStopped
            and h2Fill > config.auto.chemicalResume
            and o2Fill > config.auto.chemicalResume
    end

    if autoState.chemicalHold then
        if bothRecovered then
            autoState.chemicalHold = false
            autoState.stage = nil
        else
            autoState.stage = 0
            return 0, ("HOLD H2 %.0f O2 %.0f"):format(
                h2Fill * 100,
                o2Fill * 100
            )
        end
    elseif bothFull then
        autoState.chemicalHold = true
        autoState.stage = 0
        return 0, ("FULL H2 %.0f O2 %.0f"):format(
            h2Fill * 100,
            o2Fill * 100
        )
    end

    local h = config.auto.stageHysteresis
    local stage = autoState.stage

    if not stage or stage <= 0 then
        stage = initialAutoStage(demandFill, maxLines)
    elseif stage >= 3 then
        if demandFill >= config.auto.scaleToTwo + h then
            stage = math.min(2, maxLines)
        end
    elseif stage == 2 then
        if demandFill >= config.auto.scaleToOne + h then
            stage = math.min(1, maxLines)
        elseif demandFill < config.auto.scaleToTwo - h then
            stage = maxLines
        end
    elseif stage == 1 then
        if demandFill < config.auto.scaleToOne - h then
            stage = math.min(2, maxLines)
        end
    end

    stage = math.max(0, math.min(stage, maxLines))
    autoState.stage = stage

    return stage, ("LOCAL H2 %.0f O2 %.0f"):format(
        h2Fill * 100,
        o2Fill * 100
    )
end

local function applyAutoTarget(data, targetLines)
    local changed = false
    local allOK = true

    for index, lineCfg in ipairs(config.lines or {}) do
        local desiredState = index <= targetLines and "RUN" or "STOP"
        local current = data.lines[index] and data.lines[index].state or "MISSING"

        if current ~= desiredState then
            local targetMode = desiredState == "RUN" and "DISABLED" or config.stopMode
            local ok = setLineMode(lineCfg.id, targetMode)
            changed = true
            if not ok then allOK = false end
        end
    end

    return allOK, changed
end

local function separatorChemicalSide(separatorName, device, chemicalName)
    local left = safeCall(device, "getLeftOutput")
    local right = safeCall(device, "getRightOutput")

    local leftName = type(left) == "table" and left.name or nil
    local rightName = type(right) == "table" and right.name or nil
    local mapping = separatorOutputMap[separatorName] or {
        hydrogen = separatorDefaultMap.hydrogen,
        oxygen = separatorDefaultMap.oxygen,
    }

    if leftName == "mekanism:hydrogen" then
        mapping.hydrogen = "LEFT"
        mapping.oxygen = "RIGHT"
    elseif leftName == "mekanism:oxygen" then
        mapping.oxygen = "LEFT"
        mapping.hydrogen = "RIGHT"
    end

    if rightName == "mekanism:hydrogen" then
        mapping.hydrogen = "RIGHT"
        mapping.oxygen = "LEFT"
    elseif rightName == "mekanism:oxygen" then
        mapping.oxygen = "RIGHT"
        mapping.hydrogen = "LEFT"
    end

    if mapping.hydrogen and mapping.oxygen then
        separatorDefaultMap.hydrogen = mapping.hydrogen
        separatorDefaultMap.oxygen = mapping.oxygen
    end

    separatorOutputMap[separatorName] = mapping

    if chemicalName == "mekanism:hydrogen" then
        return mapping.hydrogen
    elseif chemicalName == "mekanism:oxygen" then
        return mapping.oxygen
    end

    return nil
end

local function setSeparatorOutputDumpingMode(device, side, mode)
    local setter
    local getter

    if side == "LEFT" then
        setter = device.setLeftOutputDumpingMode
        getter = device.getLeftOutputDumpingMode
    elseif side == "RIGHT" then
        setter = device.setRightOutputDumpingMode
        getter = device.getRightOutputDumpingMode
    else
        return false, "UNKNOWN SIDE"
    end

    if type(setter) ~= "function" or type(getter) ~= "function" then
        return false, "DUMP API MISSING"
    end

    local current = safeCall(device, side == "LEFT"
        and "getLeftOutputDumpingMode"
        or "getRightOutputDumpingMode")

    if current == mode then
        return true
    end

    local ok, err = pcall(setter, mode)
    if not ok then
        return false, tostring(err)
    end

    local applied = safeCall(device, side == "LEFT"
        and "getLeftOutputDumpingMode"
        or "getRightOutputDumpingMode")

    if applied ~= mode then
        return false, ("EXPECTED %s GOT %s"):format(
            tostring(mode),
            tostring(applied)
        )
    end

    return true
end

local function updateOverflowState(data, targetLines)
    local h2External = ratio(data.hydrogen, data.hydrogenCapacity)
    local o2External = ratio(data.oxygen, data.oxygenCapacity)
    local enable = config.auto.overflowEnable
    local disable = config.auto.overflowDisable

    -- Surplus persistant :
    -- si un buffer externe est plein alors que l'autre gaz reste demande,
    -- on maintient le dump du gaz excedentaire EN CONTINU.
    if targetLines <= 0 then
        autoState.surplusHydrogenHold = false
        autoState.surplusOxygenHold = false
    else
        if autoState.surplusHydrogenHold then
            if h2External <= config.auto.chemicalResume
                or o2External >= config.auto.chemicalStop then
                autoState.surplusHydrogenHold = false
            end
        elseif h2External >= config.auto.chemicalStop
            and o2External < config.auto.chemicalStop then
            autoState.surplusHydrogenHold = true
        end

        if autoState.surplusOxygenHold then
            if o2External <= config.auto.chemicalResume
                or h2External >= config.auto.chemicalStop then
                autoState.surplusOxygenHold = false
            end
        elseif o2External >= config.auto.chemicalStop
            and h2External < config.auto.chemicalStop then
            autoState.surplusOxygenHold = true
        end
    end

    local activeSeparators = {}
    for index, lineCfg in ipairs(config.lines or {}) do
        if index <= targetLines then
            activeSeparators[lineCfg.separator] = true
        end
    end

    local machineByName = {}
    for _, machine in ipairs(data.machines or {}) do
        machineByName[machine.name] = machine
    end

    local anyH2Dump = false
    local anyO2Dump = false
    local allOK = true
    autoState.overflowError = nil

    for _, separator in ipairs(data.devices.separators or {}) do
        local machine = machineByName[separator.name]
        local lineIsActive = activeSeparators[separator.name] == true

        local h2Side =
            machine and machine.hydrogenSide
            or separatorChemicalSide(separator.name, separator.dev, "mekanism:hydrogen")

        local o2Side =
            machine and machine.oxygenSide
            or separatorChemicalSide(separator.name, separator.dev, "mekanism:oxygen")

        local h2Internal = machine and machine.hydrogenFill or nil
        local o2Internal = machine and machine.oxygenFill or nil

        local currentH2Dump =
            (h2Side == "LEFT" and machine and machine.leftDumpMode == "DUMPING")
            or (h2Side == "RIGHT" and machine and machine.rightDumpMode == "DUMPING")

        local currentO2Dump =
            (o2Side == "LEFT" and machine and machine.leftDumpMode == "DUMPING")
            or (o2Side == "RIGHT" and machine and machine.rightDumpMode == "DUMPING")

        local needO2 = o2External < config.auto.chemicalStop
        local needH2 = h2External < config.auto.chemicalStop

        local dumpH2 = false
        local dumpO2 = false

        if lineIsActive and autoState.surplusHydrogenHold and needO2 then
            dumpH2 = true
        elseif lineIsActive and needO2 and type(h2Internal) == "number" then
            -- Securite interne secondaire : evite une saturation locale
            -- meme avant que le Chemical Tank externe soit plein.
            if currentH2Dump then
                dumpH2 = h2Internal > disable
            else
                dumpH2 = h2Internal >= enable
            end
        end

        if lineIsActive and autoState.surplusOxygenHold and needH2 then
            dumpO2 = true
        elseif lineIsActive and needH2 and type(o2Internal) == "number" then
            if currentO2Dump then
                dumpO2 = o2Internal > disable
            else
                dumpO2 = o2Internal >= enable
            end
        end

        local h2Mode = dumpH2 and "DUMPING" or "IDLE"
        local o2Mode = dumpO2 and "DUMPING" or "IDLE"

        local h2OK, h2Error = true, nil
        local o2OK, o2Error = true, nil

        if h2Side then
            h2OK, h2Error =
                setSeparatorOutputDumpingMode(separator.dev, h2Side, h2Mode)
        elseif lineIsActive then
            h2OK, h2Error = false, "H2 SIDE UNKNOWN"
        end

        if o2Side then
            o2OK, o2Error =
                setSeparatorOutputDumpingMode(separator.dev, o2Side, o2Mode)
        elseif lineIsActive then
            o2OK, o2Error = false, "O2 SIDE UNKNOWN"
        end

        if dumpH2 then anyH2Dump = true end
        if dumpO2 then anyO2Dump = true end

        if not h2OK or not o2OK then
            allOK = false
            autoState.overflowError =
                separator.name .. " " .. tostring(h2Error or o2Error)
        end
    end

    autoState.overflowHydrogen = anyH2Dump
    autoState.overflowOxygen = anyO2Dump
    autoState.overflowFault = not allOK

    return allOK
end

local function moduleStatusReason(data)
    if operatingMode == "MANUAL" then
        return "MANUAL CONTROL"
    end

    if autoState.reason == "FAULT CONTROL" then
        return "FAULT CONTROL"
    end

    if autoState.overflowFault then
        if autoState.overflowError then
            return "FAULT OVERFLOW"
        end
        return "FAULT OVERFLOW"
    end

    if autoState.waterHold then
        local fill = ratio(data.water, data.waterCapacity)
        return ("HOLD WATER %.0f%%"):format(fill * 100)
    end

    if autoState.chemicalHold then
        return "BUFFER HOLD"
    end

    if autoState.overflowHydrogen then
        return "DUMP H2 -> O2"
    end

    if autoState.overflowOxygen then
        return "DUMP O2 -> H2"
    end

    local h2Fill = ratio(data.hydrogen, data.hydrogenCapacity)
    local o2Fill = ratio(data.oxygen, data.oxygenCapacity)

    if h2Fill >= config.auto.chemicalStop
        and o2Fill >= config.auto.chemicalStop then
        return "BUFFER FULL"
    end

    local demandName = h2Fill <= o2Fill and "H2" or "O2"
    local demandFill = math.min(h2Fill, o2Fill)

    return ("DEMAND %s %.0f%%"):format(demandName, demandFill * 100)
end

local function computeRuntimeState(data)
    if not data then return "FAULT" end

    local devices = data.devices or {}
    if #(devices.separators or {}) == 0
        or #(devices.pumps or {}) == 0
        or #(devices.waterTanks or {}) == 0
        or #(devices.hydrogenTanks or {}) == 0
        or #(devices.oxygenTanks or {}) == 0 then
        return "FAULT"
    end

    for _, line in ipairs(data.lines or {}) do
        if line.state == "RUN" then return "ACTIVE" end
    end

    if operatingMode == "AUTO" and autoState.chemicalHold then
        return "SLEEP"
    end

    return "IDLE"
end

local function buildModuleStatus(data)
    local activeLines = 0
    local hasMissing = false
    local hasMixed = false
    local alarms = {}

    for _, line in ipairs(data.lines or {}) do
        if line.state == "RUN" then
            activeLines = activeLines + 1
        elseif line.state == "MISSING" then
            hasMissing = true
        elseif line.state == "MIXED" then
            hasMixed = true
        end
    end

    local devices = data.devices
    local criticalMissing =
        #devices.separators == 0
        or #devices.pumps == 0
        or #devices.waterTanks == 0
        or #devices.hydrogenTanks == 0
        or #devices.oxygenTanks == 0

    local health = "OK"

    if criticalMissing
        or hasMissing
        or autoState.reason == "FAULT CONTROL"
        or autoState.overflowFault then
        health = "FAULT"
    elseif hasMixed or data.separatorResponding < #devices.separators then
        health = "WARN"
    end

    if criticalMissing then table.insert(alarms, "CRITICAL PERIPHERAL MISSING") end
    if hasMissing then table.insert(alarms, "LINE MISSING") end
    if hasMixed then table.insert(alarms, "LINE MIXED") end
    if autoState.reason == "FAULT CONTROL" then table.insert(alarms, "CONTROL FAILURE") end
    if autoState.overflowFault then table.insert(alarms, "OVERFLOW CONTROL FAILURE") end

    local state

    if activeLines > 0 then
        state = "RUN"
    elseif operatingMode == "AUTO"
        and (autoState.waterHold or autoState.chemicalHold) then
        state = "HOLD"
    elseif operatingMode == "MANUAL" and data.controlState == "STOP" then
        state = "STOP"
    else
        state = "IDLE"
    end

    return {
        contract = 1,
        id = config.status.id,
        label = config.status.label,
        type = config.status.type,
        version = PROGRAM_VERSION,

        mode = operatingMode,
        state = state,
        health = health,
        runtimeState = computeRuntimeState(data),
        runtime = {
            sleepSeconds = config.runtime.sleepSeconds,
            idleSeconds = config.runtime.idleSeconds,
            activeSeconds = config.runtime.activeSeconds,
            lastPoll = runtimeState.lastPoll,
        },
        reason = moduleStatusReason(data),

        activeLines = activeLines,
        totalLines = #(config.lines or {}),

        metrics = {
            water = ratio(data.water, data.waterCapacity),
            hydrogen = ratio(data.hydrogen, data.hydrogenCapacity),
            oxygen = ratio(data.oxygen, data.oxygenCapacity),
        },

        ui = {
            energy = data.energy,
            maxEnergy = data.maxEnergy,
            usage = data.usage,
            separatorResponding = data.separatorResponding,
            separatorRunning = data.separatorRunning,
            controlState = data.controlState,
            targetLines = autoState.targetLines,
            lines = data.lines,
            machines = data.machines,
        },

        alarms = alarms,
    }
end

local function loadStatusBus()
    if not fs.exists(STATUS_BUS_PATH) then
        return nil
    end

    local ok, bus = pcall(dofile, STATUS_BUS_PATH)

    if ok and type(bus) == "table" and type(bus.broadcastStatus) == "function" then
        return bus
    end

    return nil
end

local function compact(value, unit)
    if type(value) ~= "number" then return "--" end

    local absValue = math.abs(value)

    if absValue >= 1e9 then
        return string.format("%.2f G%s", value / 1e9, unit or "")
    elseif absValue >= 1e6 then
        return string.format("%.2f M%s", value / 1e6, unit or "")
    elseif absValue >= 1e3 then
        return string.format("%.2f k%s", value / 1e3, unit or "")
    end

    return string.format("%.0f%s", value, unit or "")
end

local function shortChemical(name)
    if name == "mekanism:hydrogen" then return "H2" end
    if name == "mekanism:oxygen" then return "O2" end
    if not name or name == "" then return "EMPTY" end
    return tostring(name):gsub("^mekanism:", ""):upper()
end

local function shortDumpMode(mode)
    if mode == "DUMPING" then return "DUMP" end
    if mode == "DUMPING_EXCESS" then return "EXCESS" end
    if mode == "IDLE" then return "IDLE" end
    return tostring(mode or "N/A")
end

local function machinePct(value)
    if type(value) ~= "number" then return "N/A" end
    return string.format("%.1f%%", math.max(0, math.min(1, value)) * 100)
end

local function writeAt(x, y, text, fg, bg)
    if y < 1 or y > height then return end

    x = math.max(1, x)

    monitor.setCursorPos(x, y)
    monitor.setTextColor(fg or colors.white)
    monitor.setBackgroundColor(bg or colors.black)

    local available = width - x + 1
    if available > 0 then
        monitor.write(tostring(text):sub(1, available))
    end
end

local function centered(y, text, fg, bg)
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    writeAt(x, y, text, fg, bg)
end

local function inside(bounds, x, y)
    return bounds
        and x >= bounds.x1
        and x <= bounds.x2
        and y >= bounds.y1
        and y <= bounds.y2
end

local function shortName(name, maxLen)
    if #name <= maxLen then return name end
    return name:sub(1, math.max(1, maxLen - 3)) .. "..."
end

local function drawTabs()
    local overviewLabel = "[ OVERVIEW ]"
    local machinesLabel = "[ MACHINES ]"

    local overviewBg = currentPage == "overview" and colors.blue or colors.gray
    local machinesBg = currentPage == "machines" and colors.blue or colors.gray

    writeAt(2, 3, overviewLabel, colors.white, overviewBg)
    tabOverviewBounds = {
        x1 = 2,
        x2 = 2 + #overviewLabel - 1,
        y1 = 3,
        y2 = 3,
    }

    local machineX = 2 + #overviewLabel + 2
    writeAt(machineX, 3, machinesLabel, colors.white, machinesBg)
    tabMachinesBounds = {
        x1 = machineX,
        x2 = machineX + #machinesLabel - 1,
        y1 = 3,
        y2 = 3,
    }
end

local function drawBar(y, label, amount, capacity, color)
    local fill = ratio(amount, capacity)
    local pctText = string.format("%5.1f%%", fill * 100)

    writeAt(2, y, label, colors.white)

    local barX = 14
    local barWidth = math.max(8, width - 28)
    local filled = math.floor(barWidth * fill + 0.5)

    writeAt(barX, y, string.rep(" ", barWidth), colors.white, colors.gray)

    if filled > 0 then
        writeAt(barX, y, string.rep(" ", filled), colors.black, color)
    end

    writeAt(barX + barWidth + 1, y, pctText, colors.white, colors.black)
end

local function drawModeControl(y)
    writeAt(2, y, "MODE :", colors.lightGray)

    if operatingMode == "AUTO" then
        writeAt(9, y, "AUTO", colors.lime)

        local targetText = ("TARGET %d/%d"):format(
            autoState.targetLines,
            #(config.lines or {})
        )
        writeAt(16, y, targetText, colors.white)

        local label = "[ MANUAL ]"
        local x = width - #label - 1
        writeAt(x, y, label, colors.white, colors.blue)
        modeButtonBounds = { x1 = x, x2 = x + #label - 1, y1 = y, y2 = y }
    else
        writeAt(9, y, "MANUAL", colors.yellow)

        local label = "[ AUTO ]"
        local x = width - #label - 1
        writeAt(x, y, label, colors.black, colors.lime)
        modeButtonBounds = { x1 = x, x2 = x + #label - 1, y1 = y, y2 = y }
    end
end

local function drawGlobalControls()
    local y = math.max(19, height - 2)

    if operatingMode == "AUTO" then
        writeAt(2, y, "AUTO ACTIF - CONTROLES MANUELS VERROUILLES", colors.lightGray)
        startBounds = nil
        stopBounds = nil
        return
    end

    local startLabel = "[ START ALL ]"
    local stopLabel = "[ STOP ALL ]"

    writeAt(2, y, startLabel, colors.black, colors.lime)
    startBounds = {
        x1 = 2,
        x2 = 2 + #startLabel - 1,
        y1 = y,
        y2 = y,
    }

    local stopX = 2 + #startLabel + 2
    writeAt(stopX, y, stopLabel, colors.white, colors.red)
    stopBounds = {
        x1 = stopX,
        x2 = stopX + #stopLabel - 1,
        y1 = y,
        y2 = y,
    }
end

local function drawUpdateButton(now)
    local label, fg, bg

    if updateInProgress then
        label = "[ MAJ... ]"
        fg = colors.black
        bg = colors.lime

    elseif now < updateConfirmUntil then
        label = "[ CONFIRMER ]"
        fg = colors.black
        bg = colors.orange

    else
        label = "[ MAJ ]"
        fg = colors.white
        bg = colors.blue
    end

    local x = math.max(2, width - #label - 1)

    writeAt(x, height, label, fg, bg)
    updateBounds = {
        x1 = x,
        x2 = x + #label - 1,
        y1 = height,
        y2 = height,
    }
end

local drawLineBlock

local function getProcessSummary(data)
    local running = 0
    local stopped = 0
    local abnormal = false

    for _, line in ipairs(data.lines or {}) do
        if line.state == "RUN" then
            running = running + 1
        elseif line.state == "STOP" then
            stopped = stopped + 1
        else
            abnormal = true
        end
    end

    local total = #(data.lines or {})

    if abnormal then
        return "MIXED", colors.orange
    end

    if total == 0 then
        return "NO LINES", colors.lightGray
    end

    if running > 0 then
        return ("RUN %d/%d LINES"):format(running, total), colors.lime
    end

    if stopped == total then
        return "STOP", colors.red
    end

    return "IDLE", colors.lightGray
end

local function renderOverview(data)
    local devices = data.devices

    local statusOK =
        #devices.separators > 0
        and #devices.hydrogenTanks > 0
        and #devices.oxygenTanks > 0
        and #devices.waterTanks > 0

    centered(
        5,
        statusOK and "SYSTEME ONLINE" or "PERIPHERIQUE MANQUANT",
        statusOK and colors.lime or colors.red
    )

    local processText, processColor = getProcessSummary(data)
    centered(6, "PROCESS : " .. processText, processColor)

    drawBar(8, "WATER", data.water, data.waterCapacity, colors.blue)
    drawBar(10, "HYDROGEN", data.hydrogen, data.hydrogenCapacity, colors.lightBlue)
    drawBar(12, "OXYGEN", data.oxygen, data.oxygenCapacity, colors.cyan)

    writeAt(
        2,
        14,
        ("Separators : %d/%d actifs | %d/%d detectes"):format(
            data.separatorRunning,
            #devices.separators,
            data.separatorResponding,
            #devices.separators
        ),
        data.separatorResponding == #devices.separators and colors.lime or colors.orange
    )

    writeAt(2, 15, "Usage      : " .. compact(data.usage, " FE/t"), colors.white)

    if data.maxEnergy > 0 then
        writeAt(
            2,
            16,
            ("Sep energy : %s / %s"):format(
                compact(data.energy, " FE"),
                compact(data.maxEnergy, " FE")
            ),
            colors.white
        )
    end

    writeAt(
        2,
        18,
        ("Buffers    : W:%d H2:%d O2:%d"):format(
            #devices.waterTanks,
            #devices.hydrogenTanks,
            #devices.oxygenTanks
        ),
        colors.lightGray
    )

    writeAt(2, 19, ("Pumps      : %d"):format(#devices.pumps), colors.lightGray)

    drawLineBlock(data)
    drawGlobalControls()
end

drawLineBlock = function(data)
    lineButtonBounds = {}

    local modeY = math.max(20, height - 9)
    drawModeControl(modeY)

    local titleY = modeY + 2
    writeAt(2, titleY, "LINES", colors.cyan)

    if operatingMode == "AUTO" then
        writeAt(10, titleY, moduleStatusReason(data), colors.lightGray)
    end

    if #data.lines == 0 then
        writeAt(10, titleY, "AUCUNE", colors.orange)
        return
    end

    local y = titleY + 1

    for _, line in ipairs(data.lines) do
        local stateColor = colors.orange
        if line.state == "RUN" then stateColor = colors.lime end
        if line.state == "STOP" then stateColor = colors.red end
        if line.state == "MISSING" then stateColor = colors.lightGray end

        writeAt(4, y, line.id, colors.white)
        writeAt(16, y, line.state, stateColor)

        if operatingMode == "AUTO" then
            writeAt(28, y, "[ AUTO ]", colors.lightGray, colors.gray)
        else
            local buttonLabel
            local targetMode
            local buttonBg
            local buttonFg

            if line.state == "RUN" then
                buttonLabel = "[ STOP ]"
                targetMode = config.stopMode
                buttonBg = colors.red
                buttonFg = colors.white
            else
                buttonLabel = "[ START ]"
                targetMode = "DISABLED"
                buttonBg = colors.lime
                buttonFg = colors.black
            end

            local buttonX = 28
            writeAt(buttonX, y, buttonLabel, buttonFg, buttonBg)

            table.insert(lineButtonBounds, {
                x1 = buttonX,
                x2 = buttonX + #buttonLabel - 1,
                y1 = y,
                y2 = y,
                id = line.id,
                targetMode = targetMode,
            })
        end

        y = y + 1
    end
end


local function renderMachines(data)
    machineButtonBounds = {}
    lineButtonBounds = {}
    prevBounds = nil
    nextBounds = nil

    centered(5, "CONTROLE MACHINES", colors.cyan)

    local firstY = 7
    local footerReserve = 4
    local rowsPerMachine = 3
    local machinesPerPage = math.max(
        1,
        math.floor((height - firstY - footerReserve + 1) / rowsPerMachine)
    )

    local total = #data.machines
    local pageCount = math.max(1, math.ceil(total / machinesPerPage))

    if machinePage > pageCount then machinePage = pageCount end
    if machinePage < 1 then machinePage = 1 end

    local startIndex = (machinePage - 1) * machinesPerPage + 1
    local endIndex = math.min(total, startIndex + machinesPerPage - 1)

    if total == 0 then
        centered(8, "AUCUNE MACHINE", colors.orange)
    else
        local y = firstY

        for index = startIndex, endIndex do
            local machine = data.machines[index]

            local kindColor = machine.kind == "PUMP" and colors.lightBlue or colors.cyan
            local stateColor = colors.orange
            if machine.state == "RUN" then stateColor = colors.lime end
            if machine.state == "STOP" then stateColor = colors.red end

            writeAt(2, y, machine.kind, kindColor)
            writeAt(8, y, shortName(machine.name, math.max(12, width - 44)), colors.white)

            local lineLabel = machine.lineId or "UNASSIGNED"
            local lineX = math.max(28, width - 32)
            writeAt(lineX, y, lineLabel, machine.lineId and colors.yellow or colors.lightGray)

            local stateX = math.max(lineX + 10, width - 18)
            writeAt(stateX, y, machine.state, stateColor)

            local buttonX

            if operatingMode == "AUTO" then
                local buttonLabel = "[ AUTO ]"
                buttonX = math.max(stateX + 7, width - #buttonLabel - 1)
                writeAt(buttonX, y, buttonLabel, colors.lightGray, colors.gray)
            else
                local buttonLabel
                local buttonMode
                local buttonBg

                if machine.state == "RUN" then
                    buttonLabel = "[ STOP ]"
                    buttonMode = config.stopMode
                    buttonBg = colors.red
                else
                    buttonLabel = "[ START ]"
                    buttonMode = "DISABLED"
                    buttonBg = colors.lime
                end

                buttonX = math.max(stateX + 7, width - #buttonLabel - 1)
                writeAt(
                    buttonX,
                    y,
                    buttonLabel,
                    buttonMode == "DISABLED" and colors.black or colors.white,
                    buttonBg
                )

                table.insert(machineButtonBounds, {
                    x1 = buttonX,
                    x2 = buttonX + #buttonLabel - 1,
                    y1 = y,
                    y2 = y,
                    name = machine.name,
                    kind = machine.kind,
                    targetMode = buttonMode,
                })
            end

            if machine.kind == "PUMP" then
                writeAt(
                    8,
                    y + 1,
                    "FLUID " .. machinePct(machine.fluidFill),
                    colors.lightGray
                )
            else
                local detail = ("WATER %s   H2 %s   O2 %s"):format(
                    machinePct(machine.waterFill),
                    machinePct(machine.hydrogenFill),
                    machinePct(machine.oxygenFill)
                )
                writeAt(8, y + 1, detail, colors.lightGray)

                local dumpDetail = ("LEFT %s:%s   RIGHT %s:%s"):format(
                    shortChemical(machine.leftChemical),
                    shortDumpMode(machine.leftDumpMode),
                    shortChemical(machine.rightChemical),
                    shortDumpMode(machine.rightDumpMode)
                )
                writeAt(8, y + 2, dumpDetail, colors.gray)
            end

            y = y + rowsPerMachine
        end
    end

    local navY = height - 2

    if machinePage > 1 then
        local label = "[ < ]"
        writeAt(2, navY, label, colors.white, colors.gray)
        prevBounds = {
            x1 = 2,
            x2 = 2 + #label - 1,
            y1 = navY,
            y2 = navY,
        }
    end

    centered(navY, ("PAGE %d/%d"):format(machinePage, pageCount), colors.lightGray)

    if machinePage < pageCount then
        local label = "[ > ]"
        local x = width - #label - 1
        writeAt(x, navY, label, colors.white, colors.gray)
        nextBounds = {
            x1 = x,
            x2 = x + #label - 1,
            y1 = navY,
            y2 = navY,
        }
    end
end

local function render()
    if HEADLESS then return end

    local now = os.epoch("utc") / 1000
    local data = dataCache

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    centered(1, "FACTORY H2/O2  v" .. PROGRAM_VERSION, colors.cyan)
    drawTabs()

    modeButtonBounds = nil
    startBounds = nil
    stopBounds = nil
    machineButtonBounds = {}
    lineButtonBounds = {}
    prevBounds = nil
    nextBounds = nil

    if not data then
        centered(6, "INITIALISATION...", colors.orange)
        drawUpdateButton(now)
        monitor.setVisible(true)
        return
    end

    if currentPage == "machines" then
        renderMachines(data)
    else
        renderOverview(data)
    end

    if actionMessage and now < actionMessageUntil then
        writeAt(2, height - 1, actionMessage, colors.yellow, colors.black)
    else
        actionMessage = nil
    end

    if updateMessage and now < updateMessageUntil then
        local x = math.max(2, width - #updateMessage - 1)
        writeAt(x, height - 1, updateMessage, colors.red, colors.black)
        updateBounds = nil
    else
        updateMessage = nil
        drawUpdateButton(now)
    end

    monitor.setVisible(true)
end

local function doUpdate()
    if not fs.exists(UPDATER_PATH) then
        updateMessage = "UPDATER ABSENT"
        updateMessageUntil = os.epoch("utc") / 1000 + 8
        render()
        return
    end

    local loaded, updater = pcall(dofile, UPDATER_PATH)

    if not loaded
        or type(updater) ~= "table"
        or type(updater.update) ~= "function" then

        updateMessage = "UPDATER INVALIDE"
        updateMessageUntil = os.epoch("utc") / 1000 + 8
        render()
        return
    end

    updateInProgress = true
    updateConfirmUntil = 0
    updateMessage = nil
    render()

    local ok, versionOrError = updater.update()

    updateInProgress = false

    if ok then
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        monitor.clear()

        centered(math.max(2, math.floor(height / 2) - 1), "MISE A JOUR OK", colors.lime)
        centered(
            math.max(3, math.floor(height / 2) + 1),
            "Version " .. tostring(versionOrError),
            colors.lightGray
        )

        sleep(1)
        os.reboot()
        return
    end

    updateMessage = "ECHEC MAJ"
    updateMessageUntil = os.epoch("utc") / 1000 + 8
    render()
end

local function controlIsLocked()
    if not controlPending then return false end

    local now = os.epoch("utc") / 1000
    if now - controlPendingSince > CONTROL_WATCHDOG_SECONDS then
        controlPending = nil
        controlPendingSince = 0
        actionMessage = "CONTROLE REINITIALISE"
        actionMessageUntil = now + 4
        return false
    end

    return true
end

local function toggleOperatingMode()
    local now = os.epoch("utc") / 1000

    if operatingMode == "AUTO" then
        operatingMode = "MANUAL"

        if dataCache then
            autoState.overflowHydrogen = false
            autoState.overflowOxygen = false
            updateOverflowState(dataCache, 0)
        end

        autoState.reason = "MANUAL"
        autoState.stage = nil
        autoState.waterHold = false
        autoState.chemicalHold = false
        autoState.overflowHydrogen = false
        autoState.overflowOxygen = false
        autoState.surplusHydrogenHold = false
        autoState.surplusOxygenHold = false
        autoState.overflowFault = false
        autoState.overflowError = nil
        actionMessage = "MODE MANUAL"
        actionMessageUntil = now + 4
    else
        operatingMode = "AUTO"
        autoState.reason = "INITIALISATION"
        autoState.stage = nil
        autoState.waterHold = false
        autoState.chemicalHold = nil
        autoState.overflowHydrogen = false
        autoState.overflowOxygen = false
        autoState.surplusHydrogenHold = false
        autoState.surplusOxygenHold = false
        autoState.overflowFault = false
        autoState.overflowError = nil
        autoState.lastTick = 0
        actionMessage = "MODE AUTO"
        actionMessageUntil = now + 4
        os.queueEvent("factory_auto_tick")
    end

    render()
end

local function queueGlobalControl(targetMode, label)
    if updateInProgress or controlIsLocked() then return end

    local now = os.epoch("utc") / 1000

    controlPending = label
    controlPendingSince = now
    actionMessage = label .. " EN COURS..."
    actionMessageUntil = now + 10
    render()

    os.queueEvent("factory_control_request", "all", "", targetMode, label)
end

local function queueLineControl(button)
    if updateInProgress or controlIsLocked() then return end

    local now = os.epoch("utc") / 1000
    local verb = button.targetMode == "DISABLED" and "START" or "STOP"

    controlPending = button.id
    controlPendingSince = now
    actionMessage = verb .. " " .. button.id .. "..."
    actionMessageUntil = now + 10
    render()

    os.queueEvent(
        "factory_control_request",
        "line",
        button.id,
        button.targetMode,
        verb .. " " .. button.id
    )
end

local function queueMachineControl(button)
    if updateInProgress or controlIsLocked() then return end

    local now = os.epoch("utc") / 1000
    local verb = button.targetMode == "DISABLED" and "START" or "STOP"

    controlPending = button.name
    controlPendingSince = now
    actionMessage = verb .. " " .. shortName(button.name, 24) .. "..."
    actionMessageUntil = now + 10
    render()

    os.queueEvent(
        "factory_control_request",
        "machine",
        button.name,
        button.targetMode,
        verb
    )
end

local function uiLoop()
    render()

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "factory_refresh" then
            controlIsLocked()
            render()

        elseif event == "monitor_touch" and p1 == monitorName then
            local x, y = p2, p3
            local now = os.epoch("utc") / 1000

            if inside(tabOverviewBounds, x, y) then
                currentPage = "overview"
                render()

            elseif inside(tabMachinesBounds, x, y) then
                currentPage = "machines"
                render()

            elseif inside(prevBounds, x, y) then
                machinePage = math.max(1, machinePage - 1)
                render()

            elseif inside(nextBounds, x, y) then
                machinePage = machinePage + 1
                render()

            elseif inside(modeButtonBounds, x, y) then
                toggleOperatingMode()

            elseif inside(startBounds, x, y) then
                queueGlobalControl("DISABLED", "START ALL")

            elseif inside(stopBounds, x, y) then
                queueGlobalControl(config.stopMode, "STOP ALL")

            else
                local handled = false

                for _, button in ipairs(lineButtonBounds) do
                    if inside(button, x, y) then
                        queueLineControl(button)
                        handled = true
                        break
                    end
                end

                if not handled then
                    for _, button in ipairs(machineButtonBounds) do
                        if inside(button, x, y) then
                            queueMachineControl(button)
                            handled = true
                            break
                        end
                    end
                end

                if not handled
                    and inside(updateBounds, x, y)
                    and not updateInProgress then

                    if now < updateConfirmUntil then
                        doUpdate()
                    else
                        updateConfirmUntil = now + 8
                        render()
                    end
                end
            end
        end
    end
end

local function controlLoop()
    while true do
        local _, scope, targetName, targetMode, label =
            os.pullEvent("factory_control_request")

        local now = os.epoch("utc") / 1000

        local protectedOK, ok, detail = pcall(function()
            if scope == "machine" then
                return setMachineMode(targetName, targetMode)
            elseif scope == "line" then
                return setLineMode(targetName, targetMode)
            end

            return setProcessMode(targetMode)
        end)

        if not protectedOK then
            actionMessage = label .. " ERREUR INTERNE"
        else
            actionMessage =
                ok and (label .. " OK  " .. shortName(detail, 30))
                or (label .. " ECHEC  " .. shortName(detail, 30))
        end

        actionMessageUntil = now + 5
        controlPending = nil
        controlPendingSince = 0

        local refreshOK, freshData = pcall(collectData)
        if refreshOK then
            dataCache = freshData
        end

        publishImmediateStatus()
        os.queueEvent("factory_refresh")
    end
end

local function autoLoop()
    while true do
        os.pullEvent("factory_auto_tick")

        if operatingMode == "AUTO"
            and not updateInProgress
            and not controlPending
            and dataCache then

            local now = os.epoch("utc") / 1000

            if now - autoState.lastTick >= config.auto.checkSeconds then
                autoState.lastTick = now

                local wasChemicalHold = autoState.chemicalHold
                local targetLines, reason = decideAutoTarget(dataCache)
                autoState.targetLines = targetLines
                autoState.reason = reason

                local overflowOK = updateOverflowState(dataCache, targetLines)
                local ok, changed = applyAutoTarget(dataCache, targetLines)

                if not overflowOK then
                    autoState.reason = "FAULT OVERFLOW"
                elseif not ok then
                    autoState.reason = "FAULT CONTROL"
                end

                if changed then
                    local refreshOK, freshData = pcall(collectData)
                    if refreshOK then
                        dataCache = freshData
                    end
                end

                if wasChemicalHold and not autoState.chemicalHold then
                    os.queueEvent("factory_module_wake", "h2o2", "AUTO_RESUME")
                end

                if publishImmediateStatus then
                    publishImmediateStatus()
                end

                os.queueEvent("factory_refresh")
            end
        end
    end
end

publishImmediateStatus = function()
    local statusBus = loadStatusBus()
    if statusBus and dataCache then
        local packet = buildModuleStatus(dataCache)
        pcall(statusBus.broadcastStatus, packet)
    end
end

local function statusLoop()
    local statusBus = loadStatusBus()

    while true do
        if not statusBus then
            statusBus = loadStatusBus()
        end

        if statusBus and dataCache then
            local packet = buildModuleStatus(dataCache)
            pcall(statusBus.broadcastStatus, packet)
        end

        sleep(config.status.publishSeconds)
    end
end

local function waitForNextPoll(seconds)
    local timer = os.startTimer(math.max(0.1, seconds))

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == timer then
            return "TIMER"
        elseif event == "factory_module_wake" and p1 == "h2o2" then
            runtimeState.wakeReason = tostring(p2 or "WAKE")
            return runtimeState.wakeReason
        end
    end
end

local function pollInterval()
    local state = computeRuntimeState(dataCache)
    runtimeState.state = state

    if state == "SLEEP" then return config.runtime.sleepSeconds end
    if state == "IDLE" then return config.runtime.idleSeconds end
    return config.runtime.activeSeconds
end

local function dataLoop()
    while true do
        local ok, freshData = pcall(collectData)

        if ok then
            dataCache = freshData

            if operatingMode == "MANUAL" and overflowResetPending then
                autoState.overflowHydrogen = false
                autoState.overflowOxygen = false
                updateOverflowState(dataCache, 0)
                overflowResetPending = false
            end

            os.queueEvent("factory_refresh")
            if operatingMode == "AUTO" then
                os.queueEvent("factory_auto_tick")
            end
        else
            actionMessage = "TELEMETRIE: ERREUR TRANSITOIRE"
            actionMessageUntil = os.epoch("utc") / 1000 + 3
            os.queueEvent("factory_refresh")
        end

        runtimeState.lastPoll = os.epoch("utc") / 1000
        waitForNextPoll(pollInterval())
    end
end

local function supervisorModeLoop()
    while true do
        os.pullEvent("factory_h2o2_mode_toggle")
        toggleOperatingMode()
        local refreshOK, freshData = pcall(collectData)
        if refreshOK then dataCache = freshData end
        publishImmediateStatus()
        os.queueEvent("factory_refresh")
    end
end

if HEADLESS then
    parallel.waitForAny(dataLoop, controlLoop, autoLoop, statusLoop, supervisorModeLoop)
else
    parallel.waitForAny(uiLoop, dataLoop, controlLoop, autoLoop, statusLoop)
end
