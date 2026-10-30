local PROGRAM_VERSION = "0.2.0"
local STATUS_PROTOCOL = "factory.status.v1"
local CONFIG_PATH = "/config/factory_supervisor.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"
local UPDATE_MANIFEST = "programs/factory/supervisor_update_manifest.lua"

local MODULE_PROGRAMS = {
    { id = "h2o2", path = "/programs/factory/h2o2.lua" },
    { id = "biofuel", path = "/programs/factory/biofuel.lua" },
}

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
local currentView = "map"
local selectedModuleId = nil

local updateBounds = nil
local backBounds = nil
local moduleBounds = {}

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
    if available > 0 then monitor.write(tostring(value):sub(1, available)) end
end

local function centered(y, value, fg, bg)
    local text = tostring(value)
    writeAt(math.max(1, math.floor((width - #text) / 2) + 1), y, text, fg, bg or colors.black)
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

local function runtimeState(module, offline)
    if offline then return "OFFLINE", colors.red end

    local explicit = tostring(module.runtimeState or "")
    if explicit == "ACTIVE" then return explicit, colors.lime end
    if explicit == "IDLE" then return explicit, colors.lightGray end
    if explicit == "SLEEP" then return explicit, colors.cyan end
    if explicit == "FAULT" then return explicit, colors.red end

    local health = tostring(module.health or "")
    local state = tostring(module.state or "")

    if health == "FAULT" then return "FAULT", colors.red end
    if state == "RUN" then return "ACTIVE", colors.lime end
    if state == "HOLD" or state == "IDLE" then return "IDLE", colors.lightGray end
    if state == "STOP" then return "IDLE", colors.orange end

    return "UNKNOWN", colors.gray
end

local function sortedModules()
    local result = {}
    for _, module in pairs(modules) do table.insert(result, module) end
    table.sort(result, function(a, b)
        return tostring(a.label or a.id) < tostring(b.label or b.id)
    end)
    return result
end

local function inside(bounds, x, y)
    return bounds
        and x >= bounds.x1 and x <= bounds.x2
        and y >= bounds.y1 and y <= bounds.y2
end

local render

local function drawUpdateButton(now)
    local label, fg, bg
    if updateInProgress then
        label, fg, bg = "[ MAJ... ]", colors.black, colors.lime
    elseif now < updateConfirmUntil then
        label, fg, bg = "[ CONFIRMER ]", colors.black, colors.orange
    else
        label, fg, bg = "[ MAJ ]", colors.white, colors.blue
    end

    local x = math.max(2, width - #label - 1)
    writeAt(x, height, label, fg, bg)
    updateBounds = {x1=x, x2=x + #label - 1, y1=height, y2=height}
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

    local ok, versionOrError = updater.update({manifest = UPDATE_MANIFEST})
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

local function renderMap(now, list)
    moduleBounds = {}
    backBounds = nil

    centered(3, "FACTORY MODULE MAP", colors.cyan)

    if modemCount == 0 then
        centered(6, "AUCUN MODEM REDNET", colors.red)
        return
    end

    if #list == 0 then
        centered(7, "EN ATTENTE DE MODULES...", colors.orange)
        return
    end

    local columns = width >= 48 and 2 or 1
    local gap = 2
    local cardWidth = columns == 2 and math.floor((width - 5) / 2) or width - 3
    local cardHeight = 7
    local startY = 5

    for index, module in ipairs(list) do
        local col = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local x = 2 + col * (cardWidth + gap)
        local y = startY + row * cardHeight
        if y + 5 > height - 2 then break end

        local net, netColor = networkState(module, now)
        local offline = net == "OFFLINE"
        local mode = offline and "N/A" or tostring(module.mode or "N/A")
        local state = offline and "N/A" or tostring(module.state or "N/A")
        local health = offline and "N/A" or tostring(module.health or "N/A")
        local runtime, runtimeColor = runtimeState(module, offline)
        local label = tostring(module.label or module.id or "?")

        writeAt(x, y, "[ " .. label .. " ]", colors.cyan)
        writeAt(x, y + 1, "RUNTIME  " .. runtime, runtimeColor)
        writeAt(x, y + 2, "MODE     " .. mode, offline and colors.gray or modeColor(mode))
        writeAt(x, y + 3, "STATE    " .. state, offline and colors.gray or stateColor(state))
        writeAt(x, y + 4, "HEALTH   " .. health, offline and colors.gray or healthColor(health))

        local reason = tostring(module.reason or "")
        if reason == "" then reason = offline and ("NETWORK " .. net) or "Toucher pour ouvrir" end
        writeAt(x, y + 5, reason, colors.lightGray)

        moduleBounds[#moduleBounds + 1] = {
            x1=x, x2=math.min(width, x + cardWidth - 1),
            y1=y, y2=y + 5, id=module.id
        }
    end
end

local function renderMetricList(module, startY, maxY)
    local y = startY

    if type(module.details) == "table" and #module.details > 0 then
        for _, entry in ipairs(module.details) do
            if y > maxY then break end
            writeAt(4, y, tostring(entry.label or "DETAIL"), colors.gray)
            writeAt(21, y, tostring(entry.value or "N/A"), colors.white)
            y = y + 1
        end
        return y
    end

    if type(module.metrics) == "table" then
        local keys = {}
        for key in pairs(module.metrics) do table.insert(keys, key) end
        table.sort(keys)

        for _, key in ipairs(keys) do
            if y > maxY then break end
            local value = module.metrics[key]
            local display = (type(value) == "number" and value >= 0 and value <= 1) and pct(value) or tostring(value)
            writeAt(4, y, tostring(key):upper(), colors.gray)
            writeAt(21, y, display, colors.white)
            y = y + 1
        end
    end

    return y
end

local function renderDetail(now)
    moduleBounds = {}

    local module = modules[selectedModuleId]
    if not module then
        currentView = "map"
        selectedModuleId = nil
        renderMap(now, sortedModules())
        return
    end

    local backLabel = "[ < MODULES ]"
    writeAt(2, 2, backLabel, colors.white, colors.gray)
    backBounds = {x1=2, x2=2 + #backLabel - 1, y1=2, y2=2}

    centered(3, tostring(module.label or module.id), colors.cyan)
    if module.version then centered(4, "MODULE v" .. tostring(module.version), colors.gray) end

    local net, netColor = networkState(module, now)
    local offline = net == "OFFLINE"

    writeAt(4, 6, "NETWORK", colors.gray)
    writeAt(21, 6, net, netColor)

    if offline then
        centered(10, "MODULE OFFLINE", colors.red)
        centered(12, ("Dernier statut : %.0f s"):format(statusAge(module, now)), colors.gray)
        return
    end

    local mode = tostring(module.mode or "N/A")
    local state = tostring(module.state or "N/A")
    local health = tostring(module.health or "N/A")

    local runtime, runtimeColor = runtimeState(module, false)

    writeAt(4, 8, "RUNTIME", colors.gray)
    writeAt(21, 8, runtime, runtimeColor)
    writeAt(4, 9, "MODE", colors.gray)
    writeAt(21, 9, mode, modeColor(mode))
    writeAt(4, 10, "STATE", colors.gray)
    writeAt(21, 10, state, stateColor(state))
    writeAt(4, 11, "HEALTH", colors.gray)
    writeAt(21, 11, health, healthColor(health))

    if type(module.activeLines) == "number" and type(module.totalLines) == "number" then
        writeAt(4, 12, "LINES", colors.gray)
        writeAt(21, 12, ("%d/%d"):format(module.activeLines, module.totalLines), colors.white)
    end

    if module.reason and tostring(module.reason) ~= "" then
        writeAt(4, 14, "STATUS", colors.gray)
        writeAt(21, 14, tostring(module.reason), colors.lightGray)
    end

    writeAt(4, 16, "SUPERVISION", colors.cyan)
    local nextY = renderMetricList(module, 18, height - 5)

    if type(module.alarms) == "table" and #module.alarms > 0 and nextY <= height - 3 then
        writeAt(4, nextY + 1, "ALARMS", colors.red)
        local y = nextY + 2
        for _, alarm in ipairs(module.alarms) do
            if y > height - 2 then break end
            writeAt(6, y, tostring(alarm), colors.orange)
            y = y + 1
        end
    end
end

render = function()
    local now = nowSeconds()
    monitor.setVisible(false)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    centered(1, "FACTORY SUPERVISOR  v" .. PROGRAM_VERSION, colors.cyan)
    updateBounds = nil
    backBounds = nil
    moduleBounds = {}

    if currentView == "detail" then
        renderDetail(now)
    else
        renderMap(now, sortedModules())
    end

    writeAt(2, height, ("Rednet:%d | %s"):format(modemCount, STATUS_PROTOCOL), colors.gray)

    if updateMessage and now < updateMessageUntil then
        local x = math.max(2, width - #updateMessage - 1)
        writeAt(x, height, updateMessage, colors.red, colors.black)
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

local function statusLoop()
    while true do
        local event, p1, p2, p3 = os.pullEvent()

        local message = nil
        local sender = nil

        if event == "factory_local_status" then
            message = p1
            sender = os.getComputerID()
        elseif event == "rednet_message" and p3 == STATUS_PROTOCOL then
            sender = p1
            message = p2
        end

        if message and validPacket(message) then
            message.senderId = sender
            message.lastSeen = nowSeconds()
            modules[message.id] = message
            os.queueEvent("factory_supervisor_refresh")
        end
    end
end

local function runModuleProcess(moduleDef)
    while true do
        if fs.exists(moduleDef.path) then
            local ok = shell.run(moduleDef.path, "--headless")
            if not ok then
                updateMessage = "MODULE " .. tostring(moduleDef.id) .. " STOP"
                updateMessageUntil = nowSeconds() + 8
                os.queueEvent("factory_supervisor_refresh")
            end
        else
            updateMessage = "MODULE " .. tostring(moduleDef.id) .. " ABSENT"
            updateMessageUntil = nowSeconds() + 8
            os.queueEvent("factory_supervisor_refresh")
        end

        sleep(5)
    end
end

local function moduleH2O2Loop()
    runModuleProcess(MODULE_PROGRAMS[1])
end

local function moduleBiofuelLoop()
    runModuleProcess(MODULE_PROGRAMS[2])
end

local function uiLoop()
    render()

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "factory_supervisor_refresh" then
            render()

        elseif event == "monitor_touch" and p1 == monitorName then
            local x, y = p2, p3
            local now = nowSeconds()

            if inside(backBounds, x, y) then
                currentView = "map"
                selectedModuleId = nil

            else
                local handled = false

                if currentView == "map" then
                    for _, bounds in ipairs(moduleBounds) do
                        if inside(bounds, x, y) then
                            selectedModuleId = bounds.id
                            currentView = "detail"
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
        os.queueEvent("factory_supervisor_refresh")
        sleep(config.refreshSeconds)
    end
end

parallel.waitForAny(statusLoop, uiLoop, refreshLoop, moduleH2O2Loop, moduleBiofuelLoop)
