local PROGRAM_VERSION = "0.3.0"
local CONFIG_PATH = "/config/factory_h2o2.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"

local defaults = {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,
    stopMode = "HIGH",
}

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return defaults end

    local ok, cfg = pcall(dofile, CONFIG_PATH)
    if not ok or type(cfg) ~= "table" then return defaults end

    for key, value in pairs(defaults) do
        if cfg[key] == nil then cfg[key] = value end
    end

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

local updateBounds = nil
local startBounds = nil
local stopBounds = nil

local updateConfirmUntil = 0
local updateMessage = nil
local updateMessageUntil = 0
local updateInProgress = false

local actionMessage = nil
local actionMessageUntil = 0
local controlPending = nil

local dataCache = nil

local function safeCall(device, method, ...)
    if not device or type(device[method]) ~= "function" then return nil end

    local ok, result = pcall(device[method], ...)
    if ok then return result end

    return nil
end

local function normType(name)
    return tostring(peripheral.getType(name) or ""):lower()
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

    for _, name in ipairs(peripheral.getNames()) do
        local pType = normType(name)
        local device = peripheral.wrap(name)

        if pType:find("electrolyticseparator", 1, true) then
            table.insert(found.separators, { name = name, dev = device })

        elseif pType:find("electricpump", 1, true) then
            table.insert(found.pumps, { name = name, dev = device })

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
            local mode = safeCall(item.dev, "getRedstoneMode")

            if mode == "DISABLED" then
                running = running + 1
            elseif mode == config.stopMode then
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

    return {
        devices = devices,

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

local function setProcessMode(targetMode)
    local devices = dataCache and dataCache.devices or classify()

    local targets = {}

    for _, item in ipairs(devices.separators) do
        table.insert(targets, { kind = "SEP", item = item })
    end

    for _, item in ipairs(devices.pumps) do
        table.insert(targets, { kind = "PUMP", item = item })
    end

    if #targets == 0 then
        return false, "AUCUNE MACHINE"
    end

    local results = {}
    local tasks = {}

    for i = 1, #targets do
        local index = i
        local target = targets[i]

        tasks[i] = function()
            local method = target.item.dev.setRedstoneMode

            if type(method) ~= "function" then
                results[index] = { ok = false, kind = target.kind }
                return
            end

            local ok = pcall(method, targetMode)
            results[index] = { ok = ok, kind = target.kind }
        end
    end

    parallel.waitForAll(table.unpack(tasks))

    local sepOK, pumpOK = 0, 0

    for _, result in ipairs(results) do
        if result and result.ok then
            if result.kind == "SEP" then
                sepOK = sepOK + 1
            elseif result.kind == "PUMP" then
                pumpOK = pumpOK + 1
            end
        end
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
    if fg then monitor.setTextColor(fg) end
    if bg then monitor.setBackgroundColor(bg) end

    local available = width - x + 1
    if available > 0 then
        monitor.write(tostring(text):sub(1, available))
    end
end

local function centered(y, text, fg, bg)
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    writeAt(x, y, text, fg, bg)
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

local function drawControlButtons()
    local y = math.max(19, height - 2)

    local startLabel = "[ START ]"
    local stopLabel = "[ STOP ]"

    writeAt(2, y, startLabel, colors.black, colors.lime)
    startBounds = { x1 = 2, x2 = 2 + #startLabel - 1, y1 = y, y2 = y }

    local stopX = 2 + #startLabel + 2
    writeAt(stopX, y, stopLabel, colors.white, colors.red)
    stopBounds = { x1 = stopX, x2 = stopX + #stopLabel - 1, y1 = y, y2 = y }
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
    updateBounds = { x1 = x, x2 = x + #label - 1, y1 = height, y2 = height }
end

local function inside(bounds, x, y)
    return bounds
        and x >= bounds.x1
        and x <= bounds.x2
        and y >= bounds.y1
        and y <= bounds.y2
end

local function render()
    local now = os.epoch("utc") / 1000
    local data = dataCache

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    centered(1, "FACTORY H2/O2  v" .. PROGRAM_VERSION, colors.cyan)
    centered(2, "PROTO 01", colors.lightGray)

    if not data then
        centered(4, "INITIALISATION...", colors.orange)
        drawUpdateButton(now)
        monitor.setVisible(true)
        return
    end

    local devices = data.devices

    local statusOK =
        #devices.separators > 0
        and #devices.hydrogenTanks > 0
        and #devices.oxygenTanks > 0
        and #devices.waterTanks > 0

    centered(
        4,
        statusOK and "SYSTEME ONLINE" or "PERIPHERIQUE MANQUANT",
        statusOK and colors.lime or colors.red
    )

    local controlColor = colors.orange
    if data.controlState == "RUN" then controlColor = colors.lime end
    if data.controlState == "STOP" then controlColor = colors.red end

    centered(5, "PROCESS CONTROL : " .. data.controlState, controlColor)

    drawBar(7, "WATER", data.water, data.waterCapacity, colors.blue)
    drawBar(9, "HYDROGEN", data.hydrogen, data.hydrogenCapacity, colors.lightBlue)
    drawBar(11, "OXYGEN", data.oxygen, data.oxygenCapacity, colors.cyan)

    writeAt(
        2,
        13,
        ("Separators : %d/%d online"):format(data.separatorOnline, #devices.separators),
        data.separatorOnline == #devices.separators and colors.lime or colors.orange
    )

    writeAt(2, 14, "Usage      : " .. compact(data.usage, " FE/t"), colors.white)

    if data.maxEnergy > 0 then
        writeAt(
            2,
            15,
            ("Sep energy : %s / %s"):format(
                compact(data.energy, " FE"),
                compact(data.maxEnergy, " FE")
            ),
            colors.white
        )
    end

    writeAt(
        2,
        17,
        ("Buffers    : W:%d H2:%d O2:%d"):format(
            #devices.waterTanks,
            #devices.hydrogenTanks,
            #devices.oxygenTanks
        ),
        colors.lightGray
    )

    writeAt(2, 18, ("Pumps      : %d"):format(#devices.pumps), colors.lightGray)

    drawControlButtons()

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

local function uiLoop()
    render()

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "factory_refresh" then
            render()

        elseif event == "monitor_touch" and p1 == monitorName then
            local x, y = p2, p3
            local now = os.epoch("utc") / 1000

            if inside(startBounds, x, y)
                and not updateInProgress
                and not controlPending then

                controlPending = "START"
                actionMessage = "START EN COURS..."
                actionMessageUntil = now + 10
                render()
                os.queueEvent("factory_control_request", "DISABLED", "START")

            elseif inside(stopBounds, x, y)
                and not updateInProgress
                and not controlPending then

                controlPending = "STOP"
                actionMessage = "STOP EN COURS..."
                actionMessageUntil = now + 10
                render()
                os.queueEvent("factory_control_request", config.stopMode, "STOP")

            elseif inside(updateBounds, x, y) and not updateInProgress then
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

local function controlLoop()
    while true do
        local _, targetMode, label = os.pullEvent("factory_control_request")

        local ok, detail = setProcessMode(targetMode)
        local now = os.epoch("utc") / 1000

        actionMessage =
            ok and (label .. " OK  " .. detail)
            or (label .. " ECHEC  " .. detail)

        actionMessageUntil = now + 5
        controlPending = nil

        dataCache = collectData()
        os.queueEvent("factory_refresh")
    end
end

local function dataLoop()
    while true do
        dataCache = collectData()
        os.queueEvent("factory_refresh")
        sleep(config.refreshSeconds)
    end
end

parallel.waitForAny(uiLoop, dataLoop, controlLoop)
