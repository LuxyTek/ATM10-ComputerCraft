local CONFIG_PATH = "/config/power.lua"

local defaults = {
    title = "MEKANISM POWER",
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,
    devices = {},
    showDevices = true,
    lowThreshold = 0.25,
    warningThreshold = 0.60,
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

local function writeAt(x, y, text, fg, bg)
    local width, height = monitor.getSize()
    if y < 1 or y > height or x > width then return end

    x = math.max(1, x)
    local available = width - x + 1
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

local function drawBar(y, ratio)
    local width, height = monitor.getSize()
    if y < 1 or y > height then return end

    local x = 3
    local barWidth = math.max(1, width - 4)
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
    else
        monitor.write(string.rep("#", filled) .. string.rep("-", barWidth - filled))
    end
end

local previousEnergy = nil
local previousTime = nil

while true do
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

    local now = os.epoch("utc") / 1000
    local netPerTick = nil

    if previousEnergy and previousTime and now > previousTime then
        netPerTick = (totalEnergy - previousEnergy) / ((now - previousTime) * 20)
    end

    previousEnergy = totalEnergy
    previousTime = now

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    local width, height = monitor.getSize()

    -- Header
    centered(1, config.title, colors.cyan)
    horizontalLine(2, "=", colors.gray)

    -- Main storage view
    centered(4, string.format("%.1f %%", fill * 100), colors.white)
    centered(5, formatEnergy(totalEnergy) .. " / " .. formatEnergy(totalCapacity), colors.lightGray)
    drawBar(7, fill)

    -- Network state
    local stateText = "CALCUL..."
    local stateColor = colors.lightGray
    local deltaText = "Delta net : calcul..."

    if netPerTick then
        local stableLimit = 1
        if netPerTick > stableLimit then
            stateText = "CHARGE"
            stateColor = colors.lime
        elseif netPerTick < -stableLimit then
            stateText = "DECHARGE"
            stateColor = colors.red
        else
            stateText = "STABLE"
            stateColor = colors.yellow
        end

        local sign = netPerTick > 0 and "+" or ""
        deltaText = "Delta net : " .. sign .. formatEnergy(netPerTick) .. "/t"
    end

    centered(9, stateText, stateColor)
    centered(10, deltaText, stateColor)

    horizontalLine(12, "-", colors.gray)

    -- Device table
    if #storages == 0 then
        centered(14, "AUCUN STOCKAGE DETECTE", colors.red)
        centered(15, "Commande : peripherals", colors.lightGray)
    elseif config.showDevices then
        writeAt(2, 13, "CUBE", colors.cyan)
        writeAt(math.max(10, math.floor(width * 0.30)), 13, "CHARGE", colors.cyan)
        writeAt(math.max(22, math.floor(width * 0.52)), 13, "ENERGIE", colors.cyan)

        local firstRow = 14
        local footerRow = height
        local maxRows = math.max(0, footerRow - firstRow - 1)

        for index, storage in ipairs(storages) do
            if index > maxRows then break end

            local row = firstRow + index - 1
            local pct = storage.capacity > 0 and (storage.energy / storage.capacity * 100) or 0
            local rowColor = colors.white

            if pct <= config.lowThreshold * 100 then
                rowColor = colors.red
            elseif pct <= config.warningThreshold * 100 then
                rowColor = colors.orange
            end

            writeAt(2, row, string.format("CUBE %02d", index), rowColor)
            writeAt(math.max(10, math.floor(width * 0.30)), row, string.format("%5.1f %%", pct), rowColor)
            writeAt(math.max(22, math.floor(width * 0.52)), row, formatEnergy(storage.energy), rowColor)
        end
    end

    -- Footer
    if height >= 3 then
        horizontalLine(height - 1, "-", colors.gray)
        local footer = string.format("%d stockage%s  |  refresh %.1fs",
            #storages,
            #storages > 1 and "s" or "",
            config.refreshSeconds)
        centered(height, footer, colors.lightGray)
    end

    sleep(config.refreshSeconds)
end
