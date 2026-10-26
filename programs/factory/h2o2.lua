local PROGRAM_VERSION = "0.1.0"
local CONFIG_PATH = "/config/factory_h2o2.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"

local defaults = {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,
}

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return defaults end
    local ok, cfg = pcall(dofile, CONFIG_PATH)
    if not ok or type(cfg) ~= "table" then return defaults end
    for k, v in pairs(defaults) do
        if cfg[k] == nil then cfg[k] = v end
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
local w, h = physicalMonitor.getSize()
local monitor = window.create(physicalMonitor, 1, 1, w, h, false)

local updateBounds = nil
local updateConfirmUntil = 0
local updateMessage = nil
local updateMessageUntil = 0
local updateInProgress = false

local function safeCall(device, method)
    if not device or type(device[method]) ~= "function" then return nil end
    local ok, result = pcall(device[method])
    if ok then return result end
    return nil
end

local function normType(name)
    local t = peripheral.getType(name)
    return tostring(t or ""):lower()
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
        local t = normType(name)
        local dev = peripheral.wrap(name)

        if t:find("electrolyticseparator", 1, true) then
            table.insert(found.separators, {name=name, dev=dev})
        elseif t:find("electricpump", 1, true) then
            table.insert(found.pumps, {name=name, dev=dev})
        elseif t:find("energycube", 1, true) then
            table.insert(found.energyCubes, {name=name, dev=dev})
        elseif t:find("fluidtank", 1, true) then
            local stored = safeCall(dev, "getStored")
            if type(stored) == "table" and stored.name == "minecraft:water" then
                table.insert(found.waterTanks, {name=name, dev=dev})
            end
        elseif t:find("chemicaltank", 1, true) then
            local stored = safeCall(dev, "getStored")
            local chem = type(stored) == "table" and stored.name or nil
            if chem == "mekanism:hydrogen" then
                table.insert(found.hydrogenTanks, {name=name, dev=dev})
            elseif chem == "mekanism:oxygen" then
                table.insert(found.oxygenTanks, {name=name, dev=dev})
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
        if type(cap) == "number" then capacity = capacity + cap end
    end
    return amount, capacity
end

local function sumSeparatorTelemetry(list)
    local energy, maxEnergy, usage = 0, 0, 0
    local online = 0
    for _, item in ipairs(list) do
        local e = safeCall(item.dev, "getEnergy")
        local max = safeCall(item.dev, "getMaxEnergy")
        local u = safeCall(item.dev, "getEnergyUsage")
        if type(e) == "number" then energy = energy + e end
        if type(max) == "number" then maxEnergy = maxEnergy + max end
        if type(u) == "number" then usage = usage + u end
        if safeCall(item.dev, "getInput") ~= nil then online = online + 1 end
    end
    return energy, maxEnergy, usage, online
end

local function ratio(amount, capacity)
    if not capacity or capacity <= 0 then return 0 end
    return math.max(0, math.min(1, amount / capacity))
end

local function compact(v, unit)
    if type(v) ~= "number" then return "--" end
    local a = math.abs(v)
    if a >= 1e9 then return string.format("%.2f G%s", v/1e9, unit or "") end
    if a >= 1e6 then return string.format("%.2f M%s", v/1e6, unit or "") end
    if a >= 1e3 then return string.format("%.2f k%s", v/1e3, unit or "") end
    return string.format("%.0f%s", v, unit or "")
end

local function writeAt(x, y, text, fg, bg)
    if y < 1 or y > h then return end
    monitor.setCursorPos(math.max(1, x), y)
    if fg then monitor.setTextColor(fg) end
    if bg then monitor.setBackgroundColor(bg) end
    local room = w - math.max(1, x) + 1
    if room > 0 then monitor.write(tostring(text):sub(1, room)) end
end

local function centered(y, text, fg)
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    writeAt(x, y, text, fg)
end

local function drawBar(y, label, amount, capacity, color)
    local pct = ratio(amount, capacity)
    local pctText = string.format("%5.1f%%", pct * 100)
    writeAt(2, y, label, colors.white)
    local barX = 14
    local barW = math.max(8, w - 28)
    local filled = math.floor(barW * pct + 0.5)
    writeAt(barX, y, string.rep(" ", barW), colors.white, colors.gray)
    if filled > 0 then
        writeAt(barX, y, string.rep(" ", filled), colors.black, color)
    end
    writeAt(barX + barW + 1, y, pctText, colors.white, colors.black)
end

local function drawUpdateButton(now)
    local label, bg
    if updateInProgress then
        label, bg = "[ MAJ... ]", colors.lime
    elseif now < updateConfirmUntil then
        label, bg = "[ CONFIRMER ]", colors.orange
    else
        label, bg = "[ MAJ ]", colors.blue
    end
    local x = math.max(2, w - #label - 1)
    writeAt(x, h, label, colors.white, bg)
    updateBounds = {x1=x, x2=x+#label-1, y=h}
end

local function render()
    local now = os.epoch("utc") / 1000
    local p = classify()
    local water, waterCap = sumTanks(p.waterTanks)
    local h2, h2Cap = sumTanks(p.hydrogenTanks)
    local o2, o2Cap = sumTanks(p.oxygenTanks)
    local energy, maxEnergy, usage, sepOnline = sumSeparatorTelemetry(p.separators)

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    centered(1, "FACTORY H2/O2  v" .. PROGRAM_VERSION, colors.cyan)
    centered(2, "PROTO 01 - TELEMETRIE", colors.lightGray)

    local statusOK = #p.separators > 0 and #p.hydrogenTanks > 0 and #p.oxygenTanks > 0 and #p.waterTanks > 0
    centered(4, statusOK and "SYSTEME ONLINE" or "PERIPHERIQUE MANQUANT", statusOK and colors.lime or colors.red)

    drawBar(6, "WATER", water, waterCap, colors.blue)
    drawBar(8, "HYDROGEN", h2, h2Cap, colors.lightBlue)
    drawBar(10, "OXYGEN", o2, o2Cap, colors.cyan)

    writeAt(2, 12, ("Separators : %d/%d online"):format(sepOnline, #p.separators), sepOnline == #p.separators and colors.lime or colors.orange)
    writeAt(2, 13, "Usage      : " .. compact(usage, " FE/t"), colors.white)

    if maxEnergy > 0 then
        writeAt(2, 14, ("Sep energy : %s / %s"):format(compact(energy, " FE"), compact(maxEnergy, " FE")), colors.white)
    end

    writeAt(2, 16, ("Buffers    : W:%d H2:%d O2:%d"):format(#p.waterTanks, #p.hydrogenTanks, #p.oxygenTanks), colors.lightGray)
    writeAt(2, 17, ("Pumps      : %d"):format(#p.pumps), colors.lightGray)

    if updateMessage and now < updateMessageUntil then
        writeAt(2, h, updateMessage, colors.red, colors.black)
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
        updateMessageUntil = os.epoch("utc") / 1000 + 6
        return
    end

    local okLoad, updater = pcall(dofile, UPDATER_PATH)
    if not okLoad or type(updater) ~= "table" or type(updater.update) ~= "function" then
        updateMessage = "UPDATER INVALIDE"
        updateMessageUntil = os.epoch("utc") / 1000 + 6
        return
    end

    updateInProgress = true
    render()

    local ok, versionOrError = updater.update()
    updateInProgress = false

    if ok then
        monitor.clear()
        centered(math.max(2, math.floor(h/2)-1), "MISE A JOUR OK", colors.lime)
        centered(math.max(3, math.floor(h/2)+1), "Version " .. tostring(versionOrError), colors.lightGray)
        sleep(1)
        os.reboot()
    else
        updateMessage = "ECHEC MAJ"
        updateMessageUntil = os.epoch("utc") / 1000 + 8
    end
end

render()

local timer = os.startTimer(config.refreshSeconds)

while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "timer" and p1 == timer then
        render()
        timer = os.startTimer(config.refreshSeconds)

    elseif event == "monitor_touch" and p1 == monitorName and updateBounds then
        local x, y = p2, p3
        if y == updateBounds.y and x >= updateBounds.x1 and x <= updateBounds.x2 then
            local now = os.epoch("utc") / 1000
            if now < updateConfirmUntil then
                updateConfirmUntil = 0
                doUpdate()
            else
                updateConfirmUntil = now + 5
                render()
            end
        end
    end
end
