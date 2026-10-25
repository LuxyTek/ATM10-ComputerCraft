local PROGRAM_VERSION = "4.4"
local CONFIG_PATH = "/config/power.lua"
local UPDATE_URL = "https://raw.githubusercontent.com/LuxyTek/ATM10-ComputerCraft/main/install.lua"
local UPDATE_TEMP = "/.atm10cc_update.lua"

local defaults = {
    title = "MEKANISM POWER",
    refreshSeconds = 1,
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

local function formatEnergy(value)
    local absValue = math.abs(value)
    if absValue >= 1e12 then
        return string.format("%.2f TFE", value / 1e12)
    elseif absValue >= 1e9 then
        return string.format("%.2f GFE", value / 1e9)
    elseif absValue >= 1e6 then
        return string.format("%.2f MFE", value / 1e6)
    elseif absValue >= 1e3 then
        return string.format("%.2f kFE", value / 1e3)
    end
    return string.format("%.0f FE", value)
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

local function hasMethod(name, wanted)
    local methods = peripheral.getMethods(name) or {}
    for _, method in ipairs(methods) do
        if method == wanted then
            return true
        end
    end
    return false
end

local function isEnergyStorage(name)
    if not peripheral.isPresent(name) then
        return false
    end

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

    local okEnergy, energy = pcall(device.getEnergy)
    if not okEnergy then return nil end

    local okCapacity, capacity
    if device.getEnergyCapacity then
        okCapacity, capacity = pcall(device.getEnergyCapacity)
    elseif device.getMaxEnergy then
        okCapacity, capacity = pcall(device.getMaxEnergy)
    else
        return nil
    end

    if not okCapacity then return nil end

    return {
        name = name,
        energy = energy,
        capacity = capacity,
    }
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

local function drawVerticalGauge(x, topY, bottomY, gaugeWidth, ratio)
    local height = bottomY - topY + 1
    if height <= 0 or gaugeWidth <= 0 then return end

    local filledRows = math.floor(height * ratio + 0.5)
    filledRows = math.max(0, math.min(height, filledRows))

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

        if percentOnFilled and barColor ~= colors.red then
            monitor.setTextColor(colors.black)
        else
            monitor.setTextColor(colors.white)
        end
    end

    monitor.setCursorPos(percentX, percentY)
    monitor.write(percentText)

    if monitor.isColor() then
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
    end
end

local function fillRow(y, leftX, rightX, bg)
    if not monitor.isColor() then return end
    if rightX < leftX then return end

    monitor.setCursorPos(leftX, y)
    monitor.setBackgroundColor(bg)
    monitor.write(string.rep(" ", rightX - leftX + 1))
    monitor.setBackgroundColor(colors.black)
end

local function drawMiniBar(x, y, barWidth, ratio, rightLimit)
    if barWidth <= 0 then return end

    local maxWidth = (rightLimit or select(1, monitor.getSize())) - x + 1
    barWidth = math.max(1, math.min(barWidth, maxWidth))

    local filled = math.floor(barWidth * ratio + 0.5)
    filled = math.max(0, math.min(barWidth, filled))

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

local sessionStart = os.epoch("utc") / 1000
local previousEnergy = nil
local previousTime = nil
local deltaSamples = {}
local peakConsumption = 0
local updateConfirmUntil = 0
local updateMessage = nil
local updateMessageUntil = 0
local buttonBounds = nil

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

    if #deltaSamples == 0 then
        return nil
    end

    local total = 0
    for _, sample in ipairs(deltaSamples) do
        total = total + sample.value
    end

    return total / #deltaSamples
end

local function drawUpdateButton(width, height, now)
    local confirming = now < updateConfirmUntil
    local label = confirming and "[ CONFIRMER ]" or "[ MAJ ]"
    local buttonWidth = #label
    local x = math.max(2, width - buttonWidth - 1)
    local y = height

    local fg = confirming and colors.black or colors.white
    local bg = confirming and colors.orange or colors.blue

    writeAt(x, y, label, fg, bg)
    buttonBounds = { x1 = x, x2 = x + buttonWidth - 1, y = y }
end

local function doUpdate()
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()
    centered(5, "MISE A JOUR...", colors.yellow)
    centered(7, "Telechargement GitHub", colors.lightGray)

    if fs.exists(UPDATE_TEMP) then
        fs.delete(UPDATE_TEMP)
    end

    local response, err = http.get(UPDATE_URL)
    if not response then
        updateMessage = "ECHEC MAJ"
        updateMessageUntil = os.epoch("utc") / 1000 + 8
        updateConfirmUntil = 0
        return false, err
    end

    local body = response.readAll()
    response.close()

    if not body or #body < 100 then
        updateMessage = "FICHIER MAJ INVALIDE"
        updateMessageUntil = os.epoch("utc") / 1000 + 8
        updateConfirmUntil = 0
        return false, "install.lua invalide"
    end

    local file = fs.open(UPDATE_TEMP, "w")
    if not file then
        updateMessage = "ERREUR ECRITURE"
        updateMessageUntil = os.epoch("utc") / 1000 + 8
        updateConfirmUntil = 0
        return false, "Impossible d'ecrire le fichier temporaire"
    end

    file.write(body)
    file.close()

    centered(9, "Installation...", colors.cyan)
    local ok = shell.run(UPDATE_TEMP)

    if fs.exists(UPDATE_TEMP) then
        fs.delete(UPDATE_TEMP)
    end

    if not ok then
        updateMessage = "ECHEC INSTALLATION"
        updateMessageUntil = os.epoch("utc") / 1000 + 8
        updateConfirmUntil = 0
        return false, "Installateur en erreur"
    end

    centered(11, "MAJ OK - REDEMARRAGE", colors.lime)
    sleep(1)
    os.reboot()
    return true
end

local function collectData(now)
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

    return storages, totalEnergy, totalCapacity, fill, updateTrend(now, netPerTick)
end

local function render()
    local now = os.epoch("utc") / 1000

    if now >= updateConfirmUntil then
        updateConfirmUntil = 0
    end
    if updateMessage and now >= updateMessageUntil then
        updateMessage = nil
    end

    local storages, totalEnergy, totalCapacity, fill, averageNet = collectData(now)

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    local width, height = monitor.getSize()

    centered(1, config.title .. "  v" .. PROGRAM_VERSION, colors.cyan)
    horizontalLine(2, "=", colors.gray)

    centered(4, formatEnergy(totalEnergy) .. " / " .. formatEnergy(totalCapacity), colors.white)

    local stateText = "CALCUL..."
    local stateColor = colors.lightGray
    local trendText = "Moy " .. config.trendSeconds .. "s : calcul..."
    local etaText = "Estimation : calcul..."

    if averageNet then
        local stableLimit = 1

        if averageNet > stableLimit then
            stateText = "CHARGE"
            stateColor = colors.lime
            local remaining = math.max(0, totalCapacity - totalEnergy)
            etaText = "Plein dans : " .. formatDuration(remaining / (averageNet * 20))
        elseif averageNet < -stableLimit then
            stateText = "DECHARGE"
            stateColor = colors.red
            etaText = "Autonomie : " .. formatDuration(totalEnergy / ((-averageNet) * 20))
        else
            stateText = "STABLE"
            stateColor = colors.yellow
            etaText = "Estimation : stable"
        end

        local sign = averageNet > 0 and "+" or ""
        trendText = "Moy " .. config.trendSeconds .. "s : " .. sign .. formatEnergy(averageNet) .. "/t"
    end

    centered(6, stateText, stateColor)
    centered(7, trendText, stateColor)
    centered(8, etaText, colors.lightGray)

    horizontalLine(10, "-", colors.gray)

    local gaugeWidth = math.max(7, math.min(10, math.floor(width * 0.14)))
    local gaugeX = width - gaugeWidth - 1
    local gaugeTop = 12
    local gaugeBottom = math.max(gaugeTop, height - 3)
    local contentRight = gaugeX - 2

    writeAt(gaugeX, 11, "ENERGIE", colors.cyan)

    if #storages == 0 then
        writeAt(2, 12, "AUCUN STOCKAGE DETECTE", colors.red, nil, contentRight)
        writeAt(2, 13, "Commande : peripherals", colors.lightGray, nil, contentRight)
    elseif config.showDevices then
        local labelX = 2
        local barX = 11
        local miniBarWidth = math.max(8, math.min(14, math.floor(contentRight * 0.22)))
        local percentX = barX + miniBarWidth + 2
        local energyX = percentX + 8

        writeAt(labelX, 11, "CUBE", colors.cyan, nil, contentRight)
        writeAt(barX, 11, "NIVEAU", colors.cyan, nil, contentRight)
        writeAt(percentX, 11, "%", colors.cyan, nil, contentRight)
        writeAt(energyX, 11, "ENERGIE", colors.cyan, nil, contentRight)

        local firstRow = 12
        local maxRows = math.max(0, gaugeBottom - firstRow + 1)

        for index, storage in ipairs(storages) do
            if index > maxRows then break end

            local row = firstRow + index - 1
            local ratio = storage.capacity > 0 and (storage.energy / storage.capacity) or 0
            ratio = math.max(0, math.min(1, ratio))
            local pct = ratio * 100

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
            writeAt(percentX, row, string.format("%5.1f", pct), rowColor, rowBackground, contentRight)
            writeAt(energyX, row, formatEnergy(storage.energy), rowColor, rowBackground, contentRight)
        end
    end

    drawVerticalGauge(gaugeX, gaugeTop, gaugeBottom, gaugeWidth, fill)

    if height >= 4 then
        horizontalLine(height - 2, "-", colors.gray)

        local peakText = "Pic conso : "
        if peakConsumption < 0 then
            peakText = peakText .. formatEnergy(peakConsumption) .. "/t"
        else
            peakText = peakText .. "--"
        end

        local uptimeText = "Uptime : " .. formatDuration(now - sessionStart)

        writeAt(2, height - 1, peakText, colors.lightGray)
        writeAt(math.max(2, width - #uptimeText), height - 1, uptimeText, colors.lightGray)

        local footer = string.format("%d stockage%s | refresh %.1fs",
            #storages,
            #storages > 1 and "s" or "",
            config.refreshSeconds)

        writeAt(2, height, footer, colors.lightGray)

        if updateMessage then
            local msgX = math.max(2, width - #updateMessage - 1)
            writeAt(msgX, height, updateMessage, colors.red)
            buttonBounds = nil
        else
            drawUpdateButton(width, height, now)
        end
    end
end

local function isInsideButton(x, y)
    return buttonBounds
        and y == buttonBounds.y
        and x >= buttonBounds.x1
        and x <= buttonBounds.x2
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

        if touchedMonitor == monitorName and isInsideButton(x, y) then
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
