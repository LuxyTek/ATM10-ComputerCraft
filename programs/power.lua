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

    local monitor, name
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheral.hasType(peripheralName, "monitor") then
            monitor = peripheral.wrap(peripheralName)
            name = peripheralName
            break
        end
    end

    if not monitor then
        error("Aucun monitor detecte sur le reseau CC:Tweaked")
    end

    return monitor, name
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

local function discoverStorages()
    local names = {}

    if #config.devices > 0 then
        for _, name in ipairs(config.devices) do
            if peripheral.isPresent(name) and peripheral.hasType(name, "energy_storage") then
                table.insert(names, name)
            end
        end
    else
        for _, name in ipairs(peripheral.getNames()) do
            if name ~= monitorName and peripheral.hasType(name, "energy_storage") then
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
    local okCapacity, capacity = pcall(device.getEnergyCapacity)

    if not okEnergy or not okCapacity then
        return nil
    end

    return {
        name = name,
        energy = energy,
        capacity = capacity,
    }
end

local function safeWrite(x, y, text, fg, bg)
    local width, height = monitor.getSize()
    if y < 1 or y > height or x > width then return end

    monitor.setCursorPos(math.max(1, x), y)
    if monitor.isColor() then
        if fg then monitor.setTextColor(fg) end
        if bg then monitor.setBackgroundColor(bg) end
    end

    local available = width - math.max(1, x) + 1
    monitor.write(string.sub(tostring(text), 1, available))
end

local function centered(y, text, fg)
    local width = monitor.getSize()
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    safeWrite(x, y, text, fg)
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
    centered(1, config.title, colors.cyan)

    safeWrite(2, 3, "Stocke : " .. formatEnergy(totalEnergy), colors.white)
    safeWrite(2, 4, "Capacite : " .. formatEnergy(totalCapacity), colors.white)
    safeWrite(2, 5, string.format("Charge : %.1f %%", fill * 100), colors.white)

    if netPerTick then
        local sign = netPerTick >= 0 and "+" or ""
        local netColor = netPerTick >= 0 and colors.lime or colors.red
        safeWrite(2, 6, "Delta net : " .. sign .. formatEnergy(netPerTick) .. "/t", netColor)
    else
        safeWrite(2, 6, "Delta net : calcul...", colors.lightGray)
    end

    local barWidth = math.max(1, width - 4)
    local filled = math.floor(barWidth * fill + 0.5)
    filled = math.max(0, math.min(barWidth, filled))

    local barColor = colors.lime
    if fill <= config.lowThreshold then
        barColor = colors.red
    elseif fill <= config.warningThreshold then
        barColor = colors.orange
    end

    if monitor.isColor() then
        monitor.setCursorPos(3, 8)
        monitor.setBackgroundColor(barColor)
        monitor.write(string.rep(" ", filled))
        monitor.setBackgroundColor(colors.gray)
        monitor.write(string.rep(" ", barWidth - filled))
        monitor.setBackgroundColor(colors.black)
    else
        safeWrite(3, 8, string.rep("#", filled) .. string.rep("-", barWidth - filled))
    end

    safeWrite(2, 10, "Energy Cubes / stockages : " .. #storages, colors.lightGray)

    if config.showDevices and height >= 12 then
        local row = 12
        for index, storage in ipairs(storages) do
            if row > height then break end
            local pct = storage.capacity > 0 and (storage.energy / storage.capacity * 100) or 0
            safeWrite(2, row, string.format("%02d  %6.1f%%  %s", index, pct, formatEnergy(storage.energy)), colors.white)
            row = row + 1
        end
    end

    sleep(config.refreshSeconds)
end
