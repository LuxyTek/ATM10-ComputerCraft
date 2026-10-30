local PROGRAM_VERSION = "0.2.0"
local STATUS_PROTOCOL = "factory.status.v1"
local CONFIG_PATH = "/config/factory_dashboard.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"
local UPDATE_MANIFEST = "programs/factory/dashboard_update_manifest.lua"

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
        if peripheral.hasType(name, "modem") then
            if not rednet.isOpen(name) then
                local ok = pcall(rednet.open, name)
                if ok then opened = opened + 1 end
            else
                opened = opened + 1
            end
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
local currentView = "overview"
local selectedModuleId = nil

local updateBounds = nil
local overviewBounds = nil
local prevBounds = nil
local nextBounds = nil
local moduleRowBounds = {}

local updateConfirmUntil = 0
local updateInProgress = false
local updateMessage = nil
local updateMessageUntil = 0

local function nowSeconds()
    return os.epoch("utc") / 1000
end

local function writeAt(x, y, value, fg, bg)
    if y < 1 or y > height then return end

    local safeX = math.max(1, x)
    monitor.setCursorPos(safeX, y)
    monitor.setTextColor(fg or colors.white)
    monitor.setBackgroundColor(bg or colors.black)

    local available = width - safeX + 1
    if available > 0 then
        monitor.write(tostring(value):sub(1, available))
    end
end

local function centered(y, value, fg, bg)
    local text = tostring(value)
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    writeAt(x, y, text, fg, bg or colors.black)
end

local function pct(value)
    if type(value) ~= "number" then return "N/A" end
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

local function modeColor(mode)
    if mode == "AUTO" then return colors.lime end
    if mode == "MANUAL" then return colors.yellow end
    return colors.lightGray
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

local function selectedIndex(list)
    for index, module in ipairs(list) do
        if module.id == selectedModuleId then
            return index
        end
    end

    return nil
end

local function inside(bounds, x, y)
    return bounds
        and x >= bounds.x1
        and x <= bounds.x2
        and y >= bounds.y1
        and y <= bounds.y2
end

local render

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

local function drawOverviewButton()
    local label = "[ OVERVIEW ]"
    writeAt(2, 2, label, colors.white, currentView == "overview" and colors.blue or colors.gray)
    overviewBounds = { x1 = 2, x2 = 2 + #label - 1, y1 = 2, y2 = 2 }
end

local function drawModuleNavigation(list)
    prevBounds = nil
    nextBounds = nil

    local index = selectedIndex(list)
    if not index then return end

    if index > 1 then
        local label = "[ < ]"
        writeAt(16, 2, label, colors.white, colors.gray)
        prevBounds = { x1 = 16, x2 = 16 + #label - 1, y1 = 2, y2 = 2 }
    end

    local module = list[index]
    local label = "[ " .. tostring(module.label or module.id) .. " ]"
    centered(2, label, colors.cyan)

    if index < #list then
        local nextLabel = "[ > ]"
        local x = math.max(22, width - #nextLabel - 12)
        writeAt(x, 2, nextLabel, colors.white, colors.gray)
        nextBounds = { x1 = x, x2 = x + #nextLabel - 1, y1 = 2, y2 = 2 }
    end
end

local function doUpdate()
    if not fs.exists(UPDATER_PATH) then
        updateMessage = "UPDATER ABSENT"
        updateMessageUntil = nowSeconds() + 6
        return
    end

    local loaded, updater = pcall(dofile, UPDATER_PATH)
    if not loaded or type(updater) ~= "table" or type(updater.update) ~= "function" then
        updateMessage = "UPDATER INVALIDE"
        updateMessageUntil = nowSeconds() + 6
        return
    end

    updateInProgress = true
    updateConfirmUntil = 0
    render()

    local ok, versionOrError = updater.update({
        manifest = UPDATE_MANIFEST,
    })

    updateInProgress = false

    if ok then
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        monitor.clear()
        centered(math.max(2, math.floor(height / 2) - 1), "MISE A JOUR OK", colors.lime)
        centered(math.max(3, math.floor(height / 2) + 1), "Version " .. tostring(versionOrError), colors.lightGray)
        sleep(1)
        os.reboot()
        return
    end

    updateMessage = "ECHEC MAJ"
    updateMessageUntil = nowSeconds() + 6
end

local function renderOverview(now, list)
    moduleRowBounds = {}

    local onlineCount = 0
    local faultCount = 0

    for _, module in ipairs(list) do
        local net = networkState(module, now)
        if net == "ONLINE" then onlineCount = onlineCount + 1 end
        if net ~= "OFFLINE" and module.health == "FAULT" then
            faultCount = faultCount + 1
        end
    end

    writeAt(2, 4, ("MODULES %d  ONLINE %d"):format(#list, onlineCount), colors.white)
    writeAt(
        math.max(24, width - 18),
        4,
        ("FAULTS %d"):format(faultCount),
        faultCount > 0 and colors.red or colors.lime
    )

    if modemCount == 0 then
        centered(6, "AUCUN MODEM REDNET", colors.red)
        return
    end

    if #list == 0 then
        centered(7, "EN ATTENTE DE MODULES...", colors.orange)
        centered(9, "protocol: " .. STATUS_PROTOCOL, colors.lightGray)
        return
    end

    writeAt(2, 6, "MODULE", colors.gray)
    writeAt(20, 6, "NETWORK", colors.gray)
    writeAt(31, 6, "MODE", colors.gray)
    writeAt(40, 6, "STATE", colors.gray)
    writeAt(49, 6, "HEALTH", colors.gray)

    local y = 8

    for _, module in ipairs(list) do
        if y > height - 4 then break end

        local net, netColor = networkState(module, now)
        local isOffline = net == "OFFLINE"
        local label = tostring(module.label or module.id or "?")

        writeAt(2, y, label, colors.white)
        writeAt(20, y, net, netColor)

        if isOffline then
            writeAt(31, y, "N/A", colors.gray)
            writeAt(40, y, "N/A", colors.gray)
            writeAt(49, y, "N/A", colors.gray)
            writeAt(4, y + 1, "Dernier statut indisponible", colors.gray)
        else
            local mode = tostring(module.mode or "N/A")
            local state = tostring(module.state or "N/A")
            local health = tostring(module.health or "N/A")

            writeAt(31, y, mode, modeColor(mode))
            writeAt(40, y, state, stateColor(state))
            writeAt(49, y, health, healthColor(health))

            local reason = tostring(module.reason or "")
            if reason == "" then reason = "Touchez pour ouvrir" end
            writeAt(4, y + 1, reason, colors.lightGray)
        end

        moduleRowBounds[#moduleRowBounds + 1] = {
            x1 = 1,
            x2 = width,
            y1 = y,
            y2 = math.min(height, y + 1),
            id = module.id,
        }

        y = y + 3
    end
end

local function renderMetricList(module, startY, maxY)
    local y = startY

    if type(module.details) == "table" and #module.details > 0 then
        for _, entry in ipairs(module.details) do
            if y > maxY then break end

            local label = tostring(entry.label or "METRIC")
            local value = tostring(entry.value or "N/A")

            writeAt(4, y, label, colors.gray)
            writeAt(20, y, value, colors.white)
            y = y + 1
        end

        return y
    end

    if type(module.metrics) == "table" then
        local keys = {}
        for key in pairs(module.metrics) do
            table.insert(keys, key)
        end
        table.sort(keys)

        for _, key in ipairs(keys) do
            if y > maxY then break end

            local value = module.metrics[key]
            local displayValue

            if type(value) == "number" and value >= 0 and value <= 1 then
                displayValue = pct(value)
            else
                displayValue = tostring(value)
            end

            writeAt(4, y, tostring(key):upper(), colors.gray)
            writeAt(20, y, displayValue, colors.white)
            y = y + 1
        end
    end

    return y
end

local function renderDetail(now, list)
    moduleRowBounds = {}

    local index = selectedIndex(list)
    if not index then
        currentView = "overview"
        selectedModuleId = nil
        renderOverview(now, list)
        return
    end

    local module = list[index]
    local net, netColor = networkState(module, now)
    local isOffline = net == "OFFLINE"

    centered(4, tostring(module.label or module.id), colors.cyan)

    if module.version then
        centered(5, "MODULE v" .. tostring(module.version), colors.gray)
    end

    writeAt(4, 7, "NETWORK", colors.gray)
    writeAt(20, 7, net, netColor)

    if isOffline then
        writeAt(4, 9, "MODE", colors.gray)
        writeAt(20, 9, "N/A", colors.gray)
        writeAt(4, 10, "STATE", colors.gray)
        writeAt(20, 10, "N/A", colors.gray)
        writeAt(4, 11, "HEALTH", colors.gray)
        writeAt(20, 11, "N/A", colors.gray)

        centered(15, "MODULE OFFLINE", colors.red)
        centered(17, ("Dernier statut : %.0f s"):format(statusAge(module, now)), colors.gray)
        return
    end

    local mode = tostring(module.mode or "N/A")
    local state = tostring(module.state or "N/A")
    local health = tostring(module.health or "N/A")

    writeAt(4, 9, "MODE", colors.gray)
    writeAt(20, 9, mode, modeColor(mode))

    writeAt(4, 10, "STATE", colors.gray)
    writeAt(20, 10, state, stateColor(state))

    writeAt(4, 11, "HEALTH", colors.gray)
    writeAt(20, 11, health, healthColor(health))

    if type(module.activeLines) == "number" and type(module.totalLines) == "number" then
        writeAt(4, 12, "LINES", colors.gray)
        writeAt(20, 12, ("%d/%d"):format(module.activeLines, module.totalLines), colors.white)
    end

    local reason = tostring(module.reason or "")
    if reason ~= "" then
        writeAt(4, 14, "STATUS", colors.gray)
        writeAt(20, 14, reason, colors.lightGray)
    end

    writeAt(4, 16, "DETAILS", colors.cyan)
    local nextY = renderMetricList(module, 18, height - 6)

    if type(module.alarms) == "table" and #module.alarms > 0 and nextY <= height - 4 then
        writeAt(4, nextY + 1, "ALARMS", colors.red)
        local alarmY = nextY + 2

        for _, alarm in ipairs(module.alarms) do
            if alarmY > height - 3 then break end
            writeAt(6, alarmY, tostring(alarm), colors.orange)
            alarmY = alarmY + 1
        end
    end
end

render = function()
    local now = nowSeconds()
    local list = sortedModules()

    monitor.setVisible(false)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    centered(1, "FACTORY DASHBOARD  v" .. PROGRAM_VERSION, colors.cyan)

    overviewBounds = nil
    prevBounds = nil
    nextBounds = nil
    moduleRowBounds = {}

    drawOverviewButton()

    if currentView == "module" then
        drawModuleNavigation(list)
        renderDetail(now, list)
    else
        renderOverview(now, list)
    end

    local footer = ("Rednet:%d | %s"):format(modemCount, STATUS_PROTOCOL)
    writeAt(2, height, footer, colors.gray)

    if updateMessage and now < updateMessageUntil then
        local x = math.max(2, width - #updateMessage - 1)
        writeAt(x, height, updateMessage, colors.red, colors.black)
        updateBounds = nil
    else
        updateMessage = nil
        drawUpdateButton(now)
    end

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
        local event, p1, p2, p3 = os.pullEvent()

        if event == "factory_dashboard_refresh" then
            render()

        elseif event == "monitor_touch" and p1 == monitorName then
            local x, y = p2, p3
            local now = nowSeconds()
            local list = sortedModules()

            if inside(overviewBounds, x, y) then
                currentView = "overview"
                selectedModuleId = nil

            elseif inside(prevBounds, x, y) then
                local index = selectedIndex(list)
                if index and index > 1 then
                    selectedModuleId = list[index - 1].id
                end

            elseif inside(nextBounds, x, y) then
                local index = selectedIndex(list)
                if index and index < #list then
                    selectedModuleId = list[index + 1].id
                end

            else
                local handled = false

                if currentView == "overview" then
                    for _, bounds in ipairs(moduleRowBounds) do
                        if inside(bounds, x, y) then
                            selectedModuleId = bounds.id
                            currentView = "module"
                            handled = true
                            break
                        end
                    end
                end

                if not handled and inside(updateBounds, x, y) and not updateInProgress then
                    if now < updateConfirmUntil then
                        doUpdate()
                    else
                        updateConfirmUntil = now + 8
                    end
                end
            end

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
