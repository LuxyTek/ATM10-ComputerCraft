local PROGRAM_VERSION = "5.0"
local CONFIG_PATH = "/config/power.lua"
local UPDATE_URL = "https://raw.githubusercontent.com/LuxyTek/ATM10-ComputerCraft/main/programs/power.lua"
local UPDATE_TEMP = "/programs/power.new"
local PROGRAM_PATH = "/programs/power.lua"
local UPDATE_TIMEOUT = 12

local defaults = {
    refreshSeconds = 1,
    meRefreshSeconds = 5,
    textScale = 0.5,
    monitor = nil,
    devices = {},
    showDevices = true,
    lowThreshold = 0.25,
    warningThreshold = 0.60,
    trendSeconds = 30,
}

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then
        return defaults
    end

    local ok, cfg = pcall(dofile, CONFIG_PATH)
    if not ok or type(cfg) ~= "table" then
        error("Configuration invalide : " .. tostring(cfg))
    end

    for key, value in pairs(defaults) do
        if cfg[key] == nil then
            cfg[key] = value
        end
    end

    return cfg
end

local config = loadConfig()

local function getMonitor()
    if config.monitor then
        if not peripheral.isPresent(config.monitor) then
            error("Monitor introuvable : " .. config.monitor)
        end
        return peripheral.wrap(config.monitor), config.monitor
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "monitor") then
            return peripheral.wrap(name), name
        end
    end

    error("Aucun monitor detecte sur le reseau CC:Tweaked")
end

local monitor, monitorName = getMonitor()
monitor.setTextScale(config.textScale)

local function formatCompact(value, unit)
    if value == nil then return "--" end
    local absValue = math.abs(value)
    if absValue >= 1e12 then
        return string.format("%.2f T%s", value / 1e12, unit or "")
    elseif absValue >= 1e9 then
        return string.format("%.2f G%s", value / 1e9, unit or "")
    elseif absValue >= 1e6 then
        return string.format("%.2f M%s", value / 1e6, unit or "")
    elseif absValue >= 1e3 then
        return string.format("%.2f k%s", value / 1e3, unit or "")
    end
    return string.format("%.0f %s", value, unit or "")
end

local function formatEnergy(value)
    return formatCompact(value, "FE")
end

local function formatAE(value)
    return formatCompact(value, "AE")
end

local function formatBytes(value)
    return formatCompact(value, "B")
end

local function formatDuration(seconds)
    if not seconds or seconds < 0 or seconds == math.huge then
        return "--"
    end

    seconds = math.floor(seconds + 0.5)

    if seconds < 60 then
        return string.format("%ds", seconds)
    end

    local minutes = math.floor(seconds / 60)
    local hours = math.floor(minutes / 60)
    local days = math.floor(hours / 24)

    if days > 0 then
        return string.format("%dj %02dh", days, hours % 24)
    elseif hours > 0 then
        return string.format("%dh %02dmin", hours, minutes % 60)
    end

    return string.format("%dmin %02ds", minutes, seconds % 60)
end

local function setColors(fg, bg)
    if monitor.isColor() then
        if fg then monitor.setTextColor(fg) end
        if bg then monitor.setBackgroundColor(bg) end
    end
end

local function writeAt(x, y, text, fg, bg, rightLimit)
    local width, height = monitor.getSize()
    if y < 1 or y > height or x > width then return end

    x = math.max(1, x)
    local limit = math.min(width, rightLimit or width)
    local available = limit - x + 1
    if available <= 0 then return end

    setColors(fg, bg)
    monitor.setCursorPos(x, y)
    monitor.write(string.sub(tostring(text), 1, available))
end

local function centered(y, text, fg, bg)
    local width = monitor.getSize()
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    writeAt(x, y, text, fg, bg)
end

local function horizontalLine(y, char, fg)
    local width = monitor.getSize()
    writeAt(1, y, string.rep(char or "-", width), fg)
end

local function fillRow(y, leftX, rightX, bg)
    if not monitor.isColor() or rightX < leftX then return end
    monitor.setCursorPos(leftX, y)
    monitor.setBackgroundColor(bg)
    monitor.write(string.rep(" ", rightX - leftX + 1))
    monitor.setBackgroundColor(colors.black)
end

local function drawMiniBar(x, y, barWidth, ratio, rightLimit)
    if barWidth <= 0 then return end

    local maxWidth = (rightLimit or select(1, monitor.getSize())) - x + 1
    barWidth = math.max(1, math.min(barWidth, maxWidth))

    ratio = math.max(0, math.min(1, ratio or 0))
    local filled = math.floor(barWidth * ratio + 0.5)

    local barColor = colors.lime
    if ratio <= config.lowThreshold then
        barColor = colors.red
    elseif ratio <= config.warningThreshold then
        barColor = colors.orange
    end

    monitor.setCursorPos(x, y)

    if monitor.isColor() then
        monitor.setBackgroundColor(barColor)
        monitor.write(string.rep(" ", filled))
        monitor.setBackgroundColor(colors.gray)
        monitor.write(string.rep(" ", barWidth - filled))
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
    else
        monitor.write(string.rep("#", filled) .. string.rep("-", barWidth - filled))
    end
end

local function drawVerticalGauge(x, topY, bottomY, gaugeWidth, ratio)
    local height = bottomY - topY + 1
    if height <= 0 or gaugeWidth <= 0 then return end

    ratio = math.max(0, math.min(1, ratio or 0))
    local filledRows = math.floor(height * ratio + 0.5)

    local barColor = colors.lime
    if ratio <= config.lowThreshold then
        barColor = colors.red
    elseif ratio <= config.warningThreshold then
        barColor = colors.orange
    end

    for row = 0, height - 1 do
        local y = topY + row
        local fromBottom = height - row
        local isFilled = fromBottom <= filledRows

        monitor.setCursorPos(x, y)
        if monitor.isColor() then
            monitor.setBackgroundColor(isFilled and barColor or colors.gray)
            monitor.write(string.rep(" ", gaugeWidth))
        else
            monitor.write(string.rep(isFilled and "#" or ".", gaugeWidth))
        end
    end

    local percentText = string.format("%.1f%%", ratio * 100)
    local percentY = math.floor((topY + bottomY) / 2)
    local percentX = x + math.max(0, math.floor((gaugeWidth - #percentText) / 2))

    if monitor.isColor() then
        local rowsFromBottom = bottomY - percentY + 1
        local percentOnFilled = rowsFromBottom <= filledRows
        monitor.setBackgroundColor(percentOnFilled and barColor or colors.gray)
        monitor.setTextColor(percentOnFilled and barColor ~= colors.red and colors.black or colors.white)
    end

    monitor.setCursorPos(percentX, percentY)
    monitor.write(percentText)

    if monitor.isColor() then
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
    end
end

local function hasMethod(name, wanted)
    local methods = peripheral.getMethods(name) or {}
    for _, method in ipairs(methods) do
        if method == wanted then return true end
    end
    return false
end

local function countEntries(tbl)
    if type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

local function safeCall(device, method, ...)
    if not device or type(device[method]) ~= "function" then
        return nil, false
    end

    local ok, result = pcall(device[method], ...)
    if not ok then
        return nil, false
    end

    return result, true
end

local function callFirst(device, methods, ...)
    for _, method in ipairs(methods) do
        local result, ok = safeCall(device, method, ...)
        if ok and result ~= nil then
            return result, method
        end
    end
    return nil, nil
end

local function isEnergyStorage(name)
    if not peripheral.isPresent(name) then return false end

    if peripheral.hasType(name, "energy_storage") then
        return true
    end

    return hasMethod(name, "getEnergy")
        and (hasMethod(name, "getEnergyCapacity") or hasMethod(name, "getMaxEnergy"))
end

local function discoverStorages()
    local names = {}

    if #config.devices > 0 then
        for _, name in ipairs(config.devices) do
            if isEnergyStorage(name) then
                table.insert(names, name)
            end
        end
    else
        for _, name in ipairs(peripheral.getNames()) do
            if name ~= monitorName and isEnergyStorage(name) then
                table.insert(names, name)
            end
        end
    end

    table.sort(names)
    return names
end

local function readStorage(name)
    local device = peripheral.wrap(name)
    if not device then return nil end

    local energy, okEnergy = safeCall(device, "getEnergy")
    if not okEnergy then return nil end

    local capacity
    if type(device.getEnergyCapacity) == "function" then
        capacity = select(1, safeCall(device, "getEnergyCapacity"))
    elseif type(device.getMaxEnergy) == "function" then
        capacity = select(1, safeCall(device, "getMaxEnergy"))
    end

    if capacity == nil then return nil end

    return {
        name = name,
        energy = energy,
        capacity = capacity,
    }
end

local sessionStart = os.epoch("utc") / 1000
local previousEnergy = nil
local previousTime = nil
local deltaSamples = {}
local peakConsumption = 0

local function updateTrend(now, netPerTick)
    if netPerTick then
        table.insert(deltaSamples, { time = now, value = netPerTick })
        if netPerTick < peakConsumption then
            peakConsumption = netPerTick
        end
    end

    local cutoff = now - config.trendSeconds
    while #deltaSamples > 0 and deltaSamples[1].time < cutoff do
        table.remove(deltaSamples, 1)
    end

    if #deltaSamples == 0 then return nil end

    local total = 0
    for _, sample in ipairs(deltaSamples) do
        total = total + sample.value
    end

    return total / #deltaSamples
end

local function collectPowerData(now)
    local storages = {}
    local totalEnergy = 0
    local totalCapacity = 0

    for _, name in ipairs(discoverStorages()) do
        local storage = readStorage(name)
        if storage then
            table.insert(storages, storage)
            totalEnergy = totalEnergy + storage.energy
            totalCapacity = totalCapacity + storage.capacity
        end
    end

    local fill = 0
    if totalCapacity > 0 then
        fill = math.max(0, math.min(1, totalEnergy / totalCapacity))
    end

    local netPerTick = nil
    if previousEnergy and previousTime and now > previousTime then
        netPerTick = (totalEnergy - previousEnergy) / ((now - previousTime) * 20)
    end

    previousEnergy = totalEnergy
    previousTime = now

    return {
        storages = storages,
        totalEnergy = totalEnergy,
        totalCapacity = totalCapacity,
        fill = fill,
        averageNet = updateTrend(now, netPerTick),
    }
end

local function findMEBridge()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "me_bridge") or peripheral.hasType(name, "meBridge") then
            return peripheral.wrap(name), name
        end
    end

    -- Fallback pour certaines versions/configurations d'Advanced Peripherals.
    for _, name in ipairs(peripheral.getNames()) do
        if hasMethod(name, "isConnected")
            and (hasMethod(name, "getItems") or hasMethod(name, "listItems"))
            and (hasMethod(name, "getCells") or hasMethod(name, "listCells")) then
            return peripheral.wrap(name), name
        end
    end

    return nil, nil
end

local function callList(device, modern, legacy)
    if device and type(device[modern]) == "function" then
        local ok, result = pcall(device[modern], {})
        if ok and type(result) == "table" then
            return result
        end
    end

    if legacy and device and type(device[legacy]) == "function" then
        local ok, result = pcall(device[legacy])
        if ok and type(result) == "table" then
            return result
        end
    end

    return {}
end

local function callNoArgList(device, modern, legacy)
    if device and type(device[modern]) == "function" then
        local ok, result = pcall(device[modern])
        if ok and type(result) == "table" then
            return result
        end
    end

    if legacy and device and type(device[legacy]) == "function" then
        local ok, result = pcall(device[legacy])
        if ok and type(result) == "table" then
            return result
        end
    end

    return {}
end

local function shortCellType(cell)
    local raw = tostring(cell.type or cell.cellType or "CELL")
    local lower = string.lower(raw)

    if string.find(lower, "chemical", 1, true) then return "CHEM" end
    if string.find(lower, "fluid", 1, true) or string.find(lower, ":f", 1, true) then return "FLUID" end
    if string.find(lower, "item", 1, true) or string.find(lower, ":i", 1, true) then return "ITEM" end
    return string.upper(string.sub(raw, 1, 6))
end

local function normalizeCells(cells)
    local result = {}

    for _, cell in pairs(cells or {}) do
        if type(cell) == "table" then
            local used = tonumber(cell.usedBytes or cell.used)
            local capacity = tonumber(cell.bytes or cell.capacity or cell.totalBytes)
            local ratio = nil

            if used and capacity and capacity > 0 then
                ratio = math.max(0, math.min(1, used / capacity))
            end

            table.insert(result, {
                type = shortCellType(cell),
                used = used,
                capacity = capacity,
                ratio = ratio,
            })
        end
    end

    table.sort(result, function(a, b)
        if a.ratio == nil and b.ratio == nil then return false end
        if a.ratio == nil then return false end
        if b.ratio == nil then return true end
        return a.ratio > b.ratio
    end)

    return result
end

local function resourceName(resource)
    if type(resource) ~= "table" then
        return tostring(resource or "craft")
    end

    return resource.displayName
        or resource.name
        or resource.id
        or resource.key
        or "craft"
end

local function normalizeTasks(tasks)
    local result = {}

    for _, task in pairs(tasks or {}) do
        if type(task) == "table" then
            local completion = tonumber(task.completion)
            if completion and completion > 1 then completion = completion / 100 end

            table.insert(result, {
                name = resourceName(task.resource or task.requestedItem or task.output),
                completion = completion,
                quantity = tonumber(task.quantity or task.count),
            })
        end
    end

    return result
end

local meCache = {
    lastRefresh = 0,
    data = nil,
}

local function refreshMEData(now, force)
    if not force and meCache.data and (now - meCache.lastRefresh) < config.meRefreshSeconds then
        return meCache.data
    end

    local bridge, bridgeName = findMEBridge()

    local data = {
        bridgeName = bridgeName,
        bridgeFound = bridge ~= nil,
        connected = false,
        online = false,
        cells = {},
        tasks = {},
    }

    if not bridge then
        meCache.lastRefresh = now
        meCache.data = data
        return data
    end

    data.connected = select(1, callFirst(bridge, { "isConnected" })) == true
    data.online = select(1, callFirst(bridge, { "isOnline" })) == true

    data.storedEnergy = select(1, callFirst(bridge, { "getStoredEnergy", "getEnergyStorage" }))
    data.energyCapacity = select(1, callFirst(bridge, { "getEnergyCapacity", "getMaxEnergyStorage" }))
    data.energyUsage = select(1, callFirst(bridge, { "getEnergyUsage" }))
    data.avgInjection = select(1, callFirst(bridge, { "getAvgPowerInjection" }))

    data.maxItemStorage = select(1, callFirst(bridge, { "getMaxItemStorage" }))
    data.usedItemStorage = select(1, callFirst(bridge, { "getUsedItemStorage" }))
    data.maxFluidStorage = select(1, callFirst(bridge, { "getMaxFluidStorage" }))
    data.usedFluidStorage = select(1, callFirst(bridge, { "getUsedFluidStorage" }))
    data.maxChemicalStorage = select(1, callFirst(bridge, { "getMaxChemicalStorage" }))
    data.usedChemicalStorage = select(1, callFirst(bridge, { "getUsedChemicalStorage" }))

    data.maxExternItemStorage = select(1, callFirst(bridge, { "getMaxExternItemStorage", "getTotalExternItemStorage" }))
    data.usedExternItemStorage = select(1, callFirst(bridge, { "getUsedExternItemStorage" }))
    data.maxExternFluidStorage = select(1, callFirst(bridge, { "getMaxExternFluidStorage" }))
    data.usedExternFluidStorage = select(1, callFirst(bridge, { "getUsedExternFluidStorage" }))
    data.maxExternChemicalStorage = select(1, callFirst(bridge, { "getMaxExternChemicalStorage" }))
    data.usedExternChemicalStorage = select(1, callFirst(bridge, { "getUsedExternChemicalStorage" }))

    local items = callList(bridge, "getItems", "listItems")
    local fluids = callList(bridge, "getFluids", "listFluid")
    local chemicals = callList(bridge, "getChemicals", "listGas")
    local craftables = callList(bridge, "getCraftableItems", "listCraftableItems")
    local cells = callNoArgList(bridge, "getCells", "listCells")
    local drives = callNoArgList(bridge, "getDrives", nil)
    local patterns = callNoArgList(bridge, "getPatterns", nil)
    local tasks = callNoArgList(bridge, "getCraftingTasks", nil)
    local cpus = callNoArgList(bridge, "getCraftingCPUs", nil)

    data.itemTypes = countEntries(items)
    data.fluidTypes = countEntries(fluids)
    data.chemicalTypes = countEntries(chemicals)
    data.craftableItems = countEntries(craftables)
    data.driveCount = countEntries(drives)
    data.cellCount = countEntries(cells)
    data.patternCount = countEntries(patterns)
    data.taskCount = countEntries(tasks)
    data.cpuCount = countEntries(cpus)

    data.cells = normalizeCells(cells)
    data.tasks = normalizeTasks(tasks)

    local alerts = 0
    for _, cell in ipairs(data.cells) do
        if cell.ratio and cell.ratio >= 0.90 then
            alerts = alerts + 1
        end
    end
    data.cellAlerts = alerts

    meCache.lastRefresh = now
    meCache.data = data
    return data
end

local activePage = "energy"
local tabBounds = {}
local updateButtonBounds = nil
local updateConfirmUntil = 0
local updateMessage = nil
local updateMessageUntil = 0
local updateInProgress = false

local render

local function drawTabs(width)
    local energyLabel = "[ ENERGIE ]"
    local meLabel = "[ ME / AE2 ]"

    local x1 = 2
    local x2 = x1 + #energyLabel + 2

    local function tab(label, x, active)
        local fg = active and colors.black or colors.white
        local bg = active and colors.cyan or colors.gray
        writeAt(x, 1, label, fg, bg)
        return { x1 = x, x2 = x + #label - 1, y = 1 }
    end

    tabBounds.energy = tab(energyLabel, x1, activePage == "energy")
    tabBounds.me = tab(meLabel, x2, activePage == "me")

    local version = "v" .. PROGRAM_VERSION
    writeAt(math.max(2, width - #version - 1), 1, version, colors.lightGray, colors.black)
    horizontalLine(2, "=", colors.gray)
end

local function drawUpdateButton(width, height, now)
    local label
    local fg
    local bg

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
    updateButtonBounds = { x1 = x, x2 = x + #label - 1, y = height }
end

local function failUpdate(message)
    updateInProgress = false
    updateConfirmUntil = 0
    updateMessage = message or "ECHEC MAJ"
    updateMessageUntil = os.epoch("utc") / 1000 + 8

    if fs.exists(UPDATE_TEMP) then
        fs.delete(UPDATE_TEMP)
    end
end

local function doUpdate()
    updateInProgress = true
    updateConfirmUntil = 0
    updateMessage = nil
    render()

    if fs.exists(UPDATE_TEMP) then
        fs.delete(UPDATE_TEMP)
    end

    local queued, requestError = http.request({
        url = UPDATE_URL,
        method = "GET",
        redirect = true,
        timeout = 10,
    })

    if not queued then
        failUpdate("HTTP REFUSE")
        return false, requestError
    end

    local timeoutTimer = os.startTimer(UPDATE_TIMEOUT)

    while true do
        local event, p1, p2 = os.pullEvent()

        if event == "http_success" and p1 == UPDATE_URL then
            local response = p2
            local body = response.readAll()
            response.close()

            if not body or #body < 100 or not string.find(body, "PROGRAM_VERSION", 1, true) then
                failUpdate("FICHIER INVALIDE")
                return false, "Programme telecharge invalide"
            end

            local file = fs.open(UPDATE_TEMP, "w")
            if not file then
                failUpdate("ERREUR ECRITURE")
                return false, "Impossible d'ecrire le fichier temporaire"
            end

            file.write(body)
            file.close()

            if fs.exists(PROGRAM_PATH) then
                fs.delete(PROGRAM_PATH)
            end
            fs.move(UPDATE_TEMP, PROGRAM_PATH)

            monitor.setBackgroundColor(colors.black)
            monitor.setTextColor(colors.white)
            monitor.clear()
            centered(5, "MISE A JOUR OK", colors.lime)
            centered(7, "Redemarrage...", colors.lightGray)
            sleep(1)
            os.reboot()
            return true

        elseif event == "http_failure" and p1 == UPDATE_URL then
            failUpdate("ECHEC HTTP")
            return false, p2

        elseif event == "timer" and p1 == timeoutTimer then
            failUpdate("TIMEOUT MAJ")
            return false, "Timeout de mise a jour"
        end
    end
end

local function drawCommonFooter(width, height, leftText, now)
    horizontalLine(height - 2, "-", colors.gray)

    if updateMessage then
        writeAt(2, height, leftText or "", colors.lightGray)
        local msgX = math.max(2, width - #updateMessage - 1)
        writeAt(msgX, height, updateMessage, colors.red)
        updateButtonBounds = nil
    else
        local buttonReserve = now < updateConfirmUntil and 15 or 10
        writeAt(2, height, leftText or "", colors.lightGray, colors.black, width - buttonReserve)
        drawUpdateButton(width, height, now)
    end
end

local function renderEnergyPage(now, width, height)
    local power = collectPowerData(now)

    centered(3, "MEKANISM POWER", colors.cyan)
    centered(5, formatEnergy(power.totalEnergy) .. " / " .. formatEnergy(power.totalCapacity), colors.white)

    local stateText = "CALCUL..."
    local stateColor = colors.lightGray
    local trendText = "Moy " .. config.trendSeconds .. "s : calcul..."
    local etaText = "Estimation : calcul..."

    if power.averageNet then
        local stableLimit = 1

        if power.averageNet > stableLimit then
            stateText = "CHARGE"
            stateColor = colors.lime
            local remaining = math.max(0, power.totalCapacity - power.totalEnergy)
            etaText = "Plein dans : " .. formatDuration(remaining / (power.averageNet * 20))
        elseif power.averageNet < -stableLimit then
            stateText = "DECHARGE"
            stateColor = colors.red
            etaText = "Autonomie : " .. formatDuration(power.totalEnergy / ((-power.averageNet) * 20))
        else
            stateText = "STABLE"
            stateColor = colors.yellow
            etaText = "Estimation : stable"
        end

        local sign = power.averageNet > 0 and "+" or ""
        trendText = "Moy " .. config.trendSeconds .. "s : " .. sign .. formatEnergy(power.averageNet) .. "/t"
    end

    centered(7, stateText, stateColor)
    centered(8, trendText, stateColor)
    centered(9, etaText, colors.lightGray)

    horizontalLine(11, "-", colors.gray)

    local gaugeWidth = math.max(7, math.min(10, math.floor(width * 0.14)))
    local gaugeX = width - gaugeWidth - 1
    local gaugeTop = 13
    local gaugeBottom = math.max(gaugeTop, height - 3)
    local contentRight = gaugeX - 2

    writeAt(gaugeX, 12, "ENERGIE", colors.cyan)

    if #power.storages == 0 then
        writeAt(2, 13, "AUCUN STOCKAGE DETECTE", colors.red, nil, contentRight)
        writeAt(2, 14, "Commande : peripherals", colors.lightGray, nil, contentRight)
    elseif config.showDevices then
        local labelX = 2
        local barX = 11
        local miniBarWidth = math.max(8, math.min(14, math.floor(contentRight * 0.22)))
        local percentX = barX + miniBarWidth + 2
        local energyX = percentX + 8

        writeAt(labelX, 12, "CUBE", colors.cyan, nil, contentRight)
        writeAt(barX, 12, "NIVEAU", colors.cyan, nil, contentRight)
        writeAt(percentX, 12, "%", colors.cyan, nil, contentRight)
        writeAt(energyX, 12, "ENERGIE", colors.cyan, nil, contentRight)

        local firstRow = 13
        local maxRows = math.max(0, gaugeBottom - firstRow + 1)

        for index, storage in ipairs(power.storages) do
            if index > maxRows then break end

            local row = firstRow + index - 1
            local ratio = storage.capacity > 0 and (storage.energy / storage.capacity) or 0
            ratio = math.max(0, math.min(1, ratio))

            local rowColor = colors.white
            if ratio <= config.lowThreshold then
                rowColor = colors.red
            elseif ratio <= config.warningThreshold then
                rowColor = colors.orange
            end

            local rowBackground = colors.black
            if monitor.isColor() and index % 2 == 0 then
                rowBackground = colors.gray
            end

            fillRow(row, 1, contentRight, rowBackground)
            writeAt(labelX, row, string.format("%02d", index), rowColor, rowBackground, contentRight)
            drawMiniBar(barX, row, miniBarWidth, ratio, contentRight)
            writeAt(percentX, row, string.format("%5.1f", ratio * 100), rowColor, rowBackground, contentRight)
            writeAt(energyX, row, formatEnergy(storage.energy), rowColor, rowBackground, contentRight)
        end
    end

    drawVerticalGauge(gaugeX, gaugeTop, gaugeBottom, gaugeWidth, power.fill)

    local peakText = peakConsumption < 0 and ("Pic conso : " .. formatEnergy(peakConsumption) .. "/t") or "Pic conso : --"
    local uptimeText = "Uptime : " .. formatDuration(now - sessionStart)

    writeAt(2, height - 1, peakText, colors.lightGray)
    writeAt(math.max(2, width - #uptimeText), height - 1, uptimeText, colors.lightGray)

    drawCommonFooter(width, height, string.format("%d stockage%s", #power.storages, #power.storages > 1 and "s" or ""), now)
end

local function storageRatio(used, capacity)
    if type(used) ~= "number" or type(capacity) ~= "number" or capacity <= 0 then
        return nil
    end
    return math.max(0, math.min(1, used / capacity))
end

local function drawStorageRow(y, label, used, capacity, width)
    writeAt(2, y, label, colors.white)

    local ratio = storageRatio(used, capacity)
    if ratio then
        local barX = 14
        local barWidth = math.max(8, math.min(16, math.floor(width * 0.20)))
        drawMiniBar(barX, y, barWidth, ratio, width - 2)

        local textX = barX + barWidth + 2
        writeAt(textX, y, string.format("%5.1f%%  %s / %s",
            ratio * 100,
            formatBytes(used),
            formatBytes(capacity)), colors.lightGray)
    else
        writeAt(14, y, "n/a", colors.gray)
    end
end

local function renderMEPage(now, width, height)
    local me = refreshMEData(now, false)

    centered(3, "AE2 / ME NETWORK", colors.cyan)

    if not me.bridgeFound then
        centered(6, "ME BRIDGE INTROUVABLE", colors.red)
        centered(8, "Verifie le modem et le reseau CC", colors.lightGray)
        centered(10, "Type attendu : me_bridge", colors.gray)

        drawCommonFooter(width, height, "ME Bridge : absent", now)
        return
    end

    local statusText
    local statusColor

    if me.online then
        statusText = "ONLINE"
        statusColor = colors.lime
    elseif me.connected then
        statusText = "CONNECTE / OFFLINE"
        statusColor = colors.orange
    else
        statusText = "DECONNECTE"
        statusColor = colors.red
    end

    centered(4, statusText, statusColor)

    local mid = math.floor(width / 2) + 1

    writeAt(2, 6, "ENERGIE AE", colors.cyan)
    writeAt(mid, 6, "INDEX RESEAU", colors.cyan)

    writeAt(2, 7, "Stockee   : " .. formatAE(me.storedEnergy) .. " / " .. formatAE(me.energyCapacity), colors.white)
    writeAt(2, 8, "Usage     : " .. (me.energyUsage and (formatAE(me.energyUsage) .. "/t") or "--"), colors.white)
    writeAt(2, 9, "Injection : " .. (me.avgInjection and (formatAE(me.avgInjection) .. "/t") or "--"), colors.white)

    local balance = nil
    if type(me.avgInjection) == "number" and type(me.energyUsage) == "number" then
        balance = me.avgInjection - me.energyUsage
    end
    writeAt(2, 10, "Bilan     : " .. (balance and ((balance >= 0 and "+" or "") .. formatAE(balance) .. "/t") or "--"),
        balance and (balance >= 0 and colors.lime or colors.red) or colors.lightGray)

    writeAt(mid, 7, "Items       : " .. tostring(me.itemTypes or 0), colors.white)
    writeAt(mid, 8, "Craftables  : " .. tostring(me.craftableItems or 0), colors.white)
    writeAt(mid, 9, "Patterns    : " .. tostring(me.patternCount or 0), colors.white)
    writeAt(mid, 10, string.format("Drives/Cells: %d / %d", me.driveCount or 0, me.cellCount or 0), colors.white)
    writeAt(mid, 11, "Crafts actifs: " .. tostring(me.taskCount or 0), colors.white)

    horizontalLine(12, "-", colors.gray)
    writeAt(2, 13, "STOCKAGE INTERNE", colors.cyan)

    drawStorageRow(14, "Items", me.usedItemStorage, me.maxItemStorage, width)
    drawStorageRow(15, "Fluides", me.usedFluidStorage, me.maxFluidStorage, width)
    drawStorageRow(16, "Chemicals", me.usedChemicalStorage, me.maxChemicalStorage, width)

    local externText = "Extern items : "
    if type(me.usedExternItemStorage) == "number" and type(me.maxExternItemStorage) == "number" then
        externText = externText .. string.format("%.0f / %.0f stacks", me.usedExternItemStorage, me.maxExternItemStorage)
    else
        externText = externText .. "n/a"
    end
    writeAt(2, 17, externText, colors.lightGray)

    horizontalLine(18, "-", colors.gray)

    local cellTitle = "CELLULES LES PLUS REMPLIES"
    if (me.cellAlerts or 0) > 0 then
        cellTitle = cellTitle .. "  ! " .. me.cellAlerts .. " >90%"
    end
    writeAt(2, 19, cellTitle, (me.cellAlerts or 0) > 0 and colors.orange or colors.cyan)

    local contentBottom = height - 3
    local craftColumnX = math.floor(width * 0.58)
    local cellRight = craftColumnX - 2

    writeAt(craftColumnX, 19, "CRAFTS ACTIFS", colors.cyan)

    local rowsAvailable = math.max(0, contentBottom - 19)
    local maxCellRows = math.min(#me.cells, rowsAvailable)

    for index = 1, maxCellRows do
        local cell = me.cells[index]
        local row = 19 + index
        local color = colors.white

        if cell.ratio and cell.ratio >= 0.90 then
            color = colors.red
        elseif cell.ratio and cell.ratio >= 0.75 then
            color = colors.orange
        end

        local usageText = cell.ratio and string.format("%5.1f%%", cell.ratio * 100) or "  n/a "
        local byteText = ""
        if cell.used and cell.capacity then
            byteText = " " .. formatBytes(cell.used) .. "/" .. formatBytes(cell.capacity)
        end

        writeAt(2, row, string.format("%02d %-5s %s%s", index, cell.type, usageText, byteText), color, nil, cellRight)
    end

    if #me.cells == 0 then
        writeAt(2, 20, "Aucune cellule lisible", colors.gray, nil, cellRight)
    end

    local maxTaskRows = math.min(#me.tasks, rowsAvailable)
    for index = 1, maxTaskRows do
        local task = me.tasks[index]
        local row = 19 + index
        local progress = task.completion and string.format("%3.0f%% ", task.completion * 100) or ""
        writeAt(craftColumnX, row, progress .. task.name, colors.white)
    end

    if #me.tasks == 0 then
        writeAt(craftColumnX, 20, "Aucun craft actif", colors.gray)
    end

    local footerLeft = string.format("ME:%s | Cells:%d | Drives:%d | detail:%ss",
        me.bridgeName or "?",
        me.cellCount or 0,
        me.driveCount or 0,
        tostring(config.meRefreshSeconds))

    drawCommonFooter(width, height, footerLeft, now)
end

render = function()
    local now = os.epoch("utc") / 1000

    if now >= updateConfirmUntil then
        updateConfirmUntil = 0
    end

    if updateMessage and now >= updateMessageUntil then
        updateMessage = nil
    end

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    local width, height = monitor.getSize()

    drawTabs(width)

    if activePage == "me" then
        renderMEPage(now, width, height)
    else
        renderEnergyPage(now, width, height)
    end
end

local function inside(bounds, x, y)
    return bounds
        and y == bounds.y
        and x >= bounds.x1
        and x <= bounds.x2
end

local function setPage(page)
    if activePage == page then return end

    activePage = page

    if page == "energy" then
        previousEnergy = nil
        previousTime = nil
        deltaSamples = {}
    elseif page == "me" then
        meCache.lastRefresh = 0
    end

    render()
end

render()

local timer = os.startTimer(config.refreshSeconds)

while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "timer" and p1 == timer then
        render()
        timer = os.startTimer(config.refreshSeconds)

    elseif event == "monitor_touch" then
        local touchedMonitor = p1
        local x = p2
        local y = p3

        if touchedMonitor == monitorName then
            if inside(tabBounds.energy, x, y) then
                setPage("energy")
            elseif inside(tabBounds.me, x, y) then
                setPage("me")
            elseif inside(updateButtonBounds, x, y) and not updateInProgress then
                local now = os.epoch("utc") / 1000

                if now < updateConfirmUntil then
                    doUpdate()
                    render()
                else
                    updateConfirmUntil = now + 8
                    render()
                end
            end
        end
    end
end
