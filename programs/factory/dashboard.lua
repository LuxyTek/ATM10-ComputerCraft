local PROGRAM_VERSION = "0.1.0"
local STATUS_PROTOCOL = "factory.status.v1"
local CONFIG_PATH = "/config/factory_dashboard.lua"

local defaults = {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,
    staleSeconds = 5,
    offlineSeconds = 10,
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

local function openRednet()
    local opened = 0

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") and not rednet.isOpen(name) then
            local ok = pcall(rednet.open, name)
            if ok then opened = opened + 1 end
        elseif peripheral.hasType(name, "modem") and rednet.isOpen(name) then
            opened = opened + 1
        end
    end

    return opened
end

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

local modemCount = openRednet()
local physicalMonitor, monitorName = getMonitor()
physicalMonitor.setTextScale(config.textScale)

local width, height = physicalMonitor.getSize()
local monitor = window.create(physicalMonitor, 1, 1, width, height, false)

local modules = {}

local function nowSeconds()
    return os.epoch("utc") / 1000
end

local function writeAt(x, y, value, fg, bg)
    if y < 1 or y > height then return end

    monitor.setCursorPos(math.max(1, x), y)
    monitor.setTextColor(fg or colors.white)
    monitor.setBackgroundColor(bg or colors.black)

    local available = width - math.max(1, x) + 1
    if available > 0 then
        monitor.write(tostring(value):sub(1, available))
    end
end

local function centered(y, value, fg)
    local text = tostring(value)
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    writeAt(x, y, text, fg, colors.black)
end

local function pct(value)
    if type(value) ~= "number" then return "--" end
    return string.format("%.0f%%", math.max(0, math.min(1, value)) * 100)
end

local function statusAge(module, now)
    return now - (module.lastSeen or 0)
end

local function networkState(module, now)
    local age = statusAge(module, now)

    if age > config.offlineSeconds then return "OFFLINE", colors.red end
    if age > config.staleSeconds then return "STALE", colors.orange end
    return "ONLINE", colors.lime
end

local function healthColor(health)
    if health == "FAULT" then return colors.red end
    if health == "WARN" then return colors.orange end
    if health == "OK" then return colors.lime end
    return colors.lightGray
end

local function stateColor(state)
    if state == "RUN" then return colors.lime end
    if state == "HOLD" then return colors.orange end
    if state == "STOP" then return colors.red end
    if state == "IDLE" then return colors.lightGray end
    return colors.white
end

local function sortedModules()
    local result = {}

    for _, module in pairs(modules) do
        table.insert(result, module)
    end

    table.sort(result, function(a, b)
        return tostring(a.label or a.id) < tostring(b.label or b.id)
    end)

    return result
end

local function render()
    local now = nowSeconds()

    monitor.setVisible(false)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    centered(1, "FACTORY DASHBOARD  v" .. PROGRAM_VERSION, colors.cyan)

    local list = sortedModules()
    local onlineCount = 0
    local faultCount = 0

    for _, module in ipairs(list) do
        local net = networkState(module, now)
        if net == "ONLINE" then onlineCount = onlineCount + 1 end
        if module.health == "FAULT" then faultCount = faultCount + 1 end
    end

    writeAt(2, 3, ("MODULES %d  ONLINE %d"):format(#list, onlineCount), colors.white)
    writeAt(
        math.max(24, width - 18),
        3,
        ("FAULTS %d"):format(faultCount),
        faultCount > 0 and colors.red or colors.lime
    )

    if modemCount == 0 then
        centered(5, "AUCUN MODEM REDNET", colors.red)
    elseif #list == 0 then
        centered(6, "EN ATTENTE DE MODULES...", colors.orange)
        centered(8, "protocol: " .. STATUS_PROTOCOL, colors.lightGray)
    else
        local y = 5

        for _, module in ipairs(list) do
            if y > height - 3 then break end

            local net, netColor = networkState(module, now)
            local label = tostring(module.label or module.id or "?")
            local mode = tostring(module.mode or "?")
            local state = tostring(module.state or "?")
            local health = tostring(module.health or "?")

            writeAt(2, y, label, colors.white)
            writeAt(20, y, net, netColor)
            writeAt(31, y, mode, mode == "AUTO" and colors.lime or colors.yellow)
            writeAt(40, y, state, stateColor(state))
            writeAt(49, y, health, healthColor(health))

            if type(module.activeLines) == "number" and type(module.totalLines) == "number" then
                writeAt(58, y, ("%d/%d lines"):format(module.activeLines, module.totalLines), colors.lightGray)
            end

            local metrics = type(module.metrics) == "table" and module.metrics or {}
            local detail = {}

            if metrics.water ~= nil then table.insert(detail, "W " .. pct(metrics.water)) end
            if metrics.hydrogen ~= nil then table.insert(detail, "H2 " .. pct(metrics.hydrogen)) end
            if metrics.oxygen ~= nil then table.insert(detail, "O2 " .. pct(metrics.oxygen)) end

            local reason = tostring(module.reason or "")
            local detailText = table.concat(detail, "  ")
            if reason ~= "" then
                if detailText ~= "" then detailText = detailText .. "  |  " end
                detailText = detailText .. reason
            end

            if detailText ~= "" and y + 1 <= height - 3 then
                writeAt(4, y + 1, detailText, colors.lightGray)
            end

            y = y + 3
        end
    end

    writeAt(2, height, ("Rednet:%d modem(s) | %s"):format(modemCount, STATUS_PROTOCOL), colors.gray)
    monitor.setVisible(true)
end

local function validPacket(message)
    return type(message) == "table"
        and message.contract == 1
        and type(message.id) == "string"
        and message.id ~= ""
end

local function networkLoop()
    while true do
        local _, sender, message, protocol = os.pullEvent("rednet_message")

        if protocol == STATUS_PROTOCOL and validPacket(message) then
            message.senderId = sender
            message.lastSeen = nowSeconds()
            modules[message.id] = message
            os.queueEvent("factory_dashboard_refresh")
        end
    end
end

local function uiLoop()
    render()

    while true do
        local event = os.pullEvent()

        if event == "factory_dashboard_refresh" then
            render()
        elseif event == "monitor_touch" then
            render()
        end
    end
end

local function refreshLoop()
    while true do
        os.queueEvent("factory_dashboard_refresh")
        sleep(config.refreshSeconds)
    end
end

parallel.waitForAny(networkLoop, uiLoop, refreshLoop)
