local PROGRAM_VERSION = "0.7.3"
local CONFIG_PATH = "/config/factory_h2o2.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"
local STATUS_BUS_PATH = "/programs/factory/lib/status_bus.lua"

local defaults = {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,
    stopMode = "HIGH",

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
        overflowEnable = 0.98,
        overflowDisable = 0.90,
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

local physicalMonitor, monitorName = getMonitor()
physicalMonitor.setTextScale(config.textScale)

local width, height = physicalMonitor.getSize()
local monitor = window.create(physicalMonitor, 1, 1, width, height, false)

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

local operatingMode = "MANUAL"
local autoState = {
    targetLines = 0,
    reason = "MANUAL",
    stage = nil,
    waterHold = false,
    chemicalHold = false,
    overflowHydrogen = false,
    overflowOxygen = false,
    overflowFault = false,
    lastTick = 0,
}

local dataCache = nil
local overflowResetPending = true

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
    local energy, maxEnergy, usage, online = 0, 0, 0, 0

    for _, item in ipairs(list) do
        local currentEnergy = safeCall(item.dev, "getEnergy")
        local currentMax = safeCall(item.dev, "getMaxEnergy")
        local currentUsage = safeCall(item.dev, "getEnergyUsage")
        local input = safeCall(item.dev, "getInput")

        if type(currentEnergy) == "number" then energy = energy + currentEnergy end
        if type(currentMax) == "number" then maxEnergy = maxEnergy + currentMax end
        if type(currentUsage) == "number" then usage = usage + currentUsage end
        if input ~= nil then online = online + 1 end
    end

    return energy, maxEnergy, usage, online
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

    local energy, maxEnergy, usage, separatorOnline =
        sumSeparatorTelemetry(devices.separators)

    local machines = {}

    for _, item in ipairs(devices.pumps) do
        table.insert(machines, {
            kind = "PUMP",
            name = item.name,
            state = item.state,
        })
    end

    for _, item in ipairs(devices.separators) do
        table.insert(machines, {
            kind = "SEP",
            name = item.name,
            state = item.state,
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

        separatorOnline = separatorOnline,
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

local function separatorChemicalSide(device, chemicalName)
    local left = safeCall(device, "getLeftOutput")
    local right = safeCall(device, "getRightOutput")

    if type(left) == "table" and left.name == chemicalName then
        return "LEFT"
    end

    if type(right) == "table" and right.name == chemicalName then
        return "RIGHT"
    end

    -- Le module est explicitement H2/O2 sur eau :
    -- Mekanism place H2 a gauche et O2 a droite pour cette recette.
    if chemicalName == "mekanism:hydrogen" then return "LEFT" end
    if chemicalName == "mekanism:oxygen" then return "RIGHT" end

    return nil
end

local function setSeparatorOutputDumpingMode(device, side, mode)
    if side == "LEFT" then
        if type(device.setLeftOutputDumpingMode) ~= "function" then
            return false
        end

        local current = safeCall(device, "getLeftOutputDumpingMode")
        if current == mode then return true end

        return pcall(device.setLeftOutputDumpingMode, mode)

    elseif side == "RIGHT" then
        if type(device.setRightOutputDumpingMode) ~= "function" then
            return false
        end

        local current = safeCall(device, "getRightOutputDumpingMode")
        if current == mode then return true end

        return pcall(device.setRightOutputDumpingMode, mode)
    end

    return false
end

local function updateOverflowState(data, targetLines)
    local h2Fill = ratio(data.hydrogen, data.hydrogenCapacity)
    local o2Fill = ratio(data.oxygen, data.oxygenCapacity)
    local enable = config.auto.overflowEnable
    local disable = config.auto.overflowDisable

    if targetLines <= 0 then
        autoState.overflowHydrogen = false
        autoState.overflowOxygen = false
    else
        if autoState.overflowHydrogen then
            if h2Fill <= disable or o2Fill >= config.auto.chemicalStop then
                autoState.overflowHydrogen = false
            end
        elseif h2Fill >= enable and o2Fill < config.auto.chemicalStop then
            autoState.overflowHydrogen = true
        end

        if autoState.overflowOxygen then
            if o2Fill <= disable or h2Fill >= config.auto.chemicalStop then
                autoState.overflowOxygen = false
            end
        elseif o2Fill >= enable and h2Fill < config.auto.chemicalStop then
            autoState.overflowOxygen = true
        end
    end

    local h2Mode = autoState.overflowHydrogen and "DUMPING_EXCESS" or "IDLE"
    local o2Mode = autoState.overflowOxygen and "DUMPING_EXCESS" or "IDLE"

    local allOK = true

    for _, separator in ipairs(data.devices.separators or {}) do
        local h2Side = separatorChemicalSide(separator.dev, "mekanism:hydrogen")
        local o2Side = separatorChemicalSide(separator.dev, "mekanism:oxygen")

        local h2OK = setSeparatorOutputDumpingMode(separator.dev, h2Side, h2Mode)
        local o2OK = setSeparatorOutputDumpingMode(separator.dev, o2Side, o2Mode)

        if not h2OK or not o2OK then
            allOK = false
        end
    end

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
        return "H2 EXCESS -> O2"
    end

    if autoState.overflowOxygen then
        return "O2 EXCESS -> H2"
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
    elseif hasMixed or data.separatorOnline < #devices.separators then
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
        reason = moduleStatusReason(data),

        activeLines = activeLines,
        totalLines = #(config.lines or {}),

        metrics = {
            water = ratio(data.water, data.waterCapacity),
            hydrogen = ratio(data.hydrogen, data.hydrogenCapacity),
            oxygen = ratio(data.oxygen, data.oxygenCapacity),
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

    local controlColor = colors.orange
    if data.controlState == "RUN" then controlColor = colors.lime end
    if data.controlState == "STOP" then controlColor = colors.red end

    centered(6, "PROCESS CONTROL : " .. data.controlState, controlColor)

    drawBar(8, "WATER", data.water, data.waterCapacity, colors.blue)
    drawBar(10, "HYDROGEN", data.hydrogen, data.hydrogenCapacity, colors.lightBlue)
    drawBar(12, "OXYGEN", data.oxygen, data.oxygenCapacity, colors.cyan)

    writeAt(
        2,
        14,
        ("Separators : %d/%d online"):format(data.separatorOnline, #devices.separators),
        data.separatorOnline == #devices.separators and colors.lime or colors.orange
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
    local rowsPerPage = math.max(1, height - firstY - footerReserve)
    local total = #data.machines
    local pageCount = math.max(1, math.ceil(total / rowsPerPage))

    if machinePage > pageCount then machinePage = pageCount end
    if machinePage < 1 then machinePage = 1 end

    local startIndex = (machinePage - 1) * rowsPerPage + 1
    local endIndex = math.min(total, startIndex + rowsPerPage - 1)

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

            y = y + 1
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
        autoState.overflowFault = false
        actionMessage = "MODE MANUAL"
        actionMessageUntil = now + 4
    else
        operatingMode = "AUTO"
        autoState.reason = "INITIALISATION"
        autoState.stage = nil
        autoState.waterHold = false
        autoState.chemicalHold = false
        autoState.overflowHydrogen = false
        autoState.overflowOxygen = false
        autoState.overflowFault = false
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

                os.queueEvent("factory_refresh")
            end
        end
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

        sleep(config.refreshSeconds)
    end
end

parallel.waitForAny(uiLoop, dataLoop, controlLoop, autoLoop, statusLoop)
