local PROGRAM_VERSION = "0.8.1"
local STATUS_PROTOCOL = "factory.status.v1"
local CONFIG_PATH = "/config/factory_supervisor.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"
local UPDATE_MANIFEST = "programs/factory/supervisor_update_manifest.lua"

local MODULE_PROGRAMS = {
    { id = "h2o2", path = "/programs/factory/h2o2.lua" },
    { id = "biofuel", path = "/programs/factory/biofuel.lua" },
    { id = "ethene", path = "/programs/factory/ethene.lua" },
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

local h2o2Page = "overview"
local h2o2MachinePage = 1
local h2o2TabOverviewBounds = nil
local h2o2TabMachinesBounds = nil
local h2o2ModeBounds = nil
local h2o2StartBounds = nil
local h2o2StopBounds = nil
local h2o2PrevBounds = nil
local h2o2NextBounds = nil
local h2o2LineBounds = {}
local h2o2MachineBounds = {}

local biofuelModeBounds = nil
local biofuelStartBounds = nil
local biofuelStopBounds = nil

local ethenePage = "overview"
local etheneMachinePage = 1
local etheneTabOverviewBounds = nil
local etheneTabMachinesBounds = nil
local etheneModeBounds = nil
local etheneStartBounds = nil
local etheneStopBounds = nil
local ethenePrevBounds = nil
local etheneNextBounds = nil
local etheneLineBounds = {}
local etheneMachineBounds = {}

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
    if state == "ABSENT" then return colors.red end
    if state == "WARN" or state == "UNKNOWN" then return colors.orange end
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

local function runtimeDetailText(module)
    local state = tostring(module.runtimeState or "")
    local rt = type(module.runtime) == "table" and module.runtime or {}

    if state == "SLEEP" then
        local seconds = tonumber(rt.sleepSeconds) or 600
        local minutes = math.floor(seconds / 60 + 0.5)
        return ("NEXT CHECK : ~%d min"):format(math.max(1, minutes))
    elseif state == "IDLE" then
        local seconds = tonumber(rt.idleSeconds) or 15
        return ("POLL : ~%d s"):format(math.max(1, math.floor(seconds + 0.5)))
    elseif state == "ACTIVE" then
        local seconds = tonumber(rt.activeSeconds) or 1
        return ("POLL : ~%d s"):format(math.max(1, math.floor(seconds + 0.5)))
    end

    return nil
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

local function findModule(list, id)
    for _, module in ipairs(list) do
        if module.id == id then return module end
    end
    return nil
end

local function renderMapCard(now, module, x, y, cardWidth)
    local net, netColor = networkState(module, now)
    local offline = net == "OFFLINE"
    local mode = offline and "N/A" or tostring(module.mode or "N/A")
    local state = offline and "N/A" or tostring(module.state or "N/A")
    local health = offline and "N/A" or tostring(module.health or "N/A")
    local runtime, runtimeColor = runtimeState(module, offline)
    local label = tostring(module.label or module.id or "?")

    writeAt(x, y, "[ " .. label .. " ]", colors.cyan)
    writeAt(x, y + 1, "RUNTIME  " .. runtime, runtimeColor)

    writeAt(x, y + 3, "MODE     " .. mode, offline and colors.gray or modeColor(mode))
    writeAt(x, y + 4, "STATE    " .. state, offline and colors.gray or stateColor(state))
    writeAt(x, y + 5, "HEALTH   " .. health, offline and colors.gray or healthColor(health))

    local reason = tostring(module.reason or "")
    if reason == "" then
        reason = offline and ("NETWORK " .. net) or "Toucher pour ouvrir"
    end
    writeAt(x, y + 6, reason, colors.lightGray)

    moduleBounds[#moduleBounds + 1] = {
        x1=x,
        x2=math.min(width, x + cardWidth - 1),
        y1=y,
        y2=y + 6,
        id=module.id,
    }
end

local function flowPercent(value)
    if type(value) ~= "number" then return "N/A" end
    value = math.max(0, math.min(1, value))
    local pct = value * 100
    if pct > 0 and pct < 1 then
        return ("%.1f%%"):format(pct)
    end
    return ("%.0f%%"):format(pct)
end

local function flowColor(module, now, fill, redAt, warnAt)
    local net = networkState(module, now)
    if net == "OFFLINE" or tostring(module.health or "") == "FAULT" then
        return colors.red
    end
    if type(fill) ~= "number" then return colors.gray end
    if fill <= redAt then return colors.red end
    if fill <= warnAt then return colors.orange end
    return colors.lime
end

local function drawFlow(x1, x2, y, label, color)
    if x2 < x1 then return end
    local span = x2 - x1 + 1
    writeAt(x1, y, string.rep("-", span), color)

    local text = " " .. tostring(label) .. " "
    if #text <= span then
        local tx = x1 + math.floor((span - #text) / 2)
        writeAt(tx, y, text, color, colors.black)
    end
end

local function renderGenericMap(now, list)
    local columns = width >= 48 and 2 or 1
    local gap = 2
    local cardWidth = columns == 2 and math.floor((width - 5) / 2) or width - 3
    local cardHeight = 8
    local startY = 5

    for index, module in ipairs(list) do
        local col = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local x = 2 + col * (cardWidth + gap)
        local y = startY + row * cardHeight
        if y + 6 > height - 2 then break end

        renderMapCard(now, module, x, y, cardWidth)
    end
end

local function renderConnectedMap(now, list, h2o2, biofuel, ethene)
    local cardWidth = math.min(24, math.max(20, math.floor((width - 8) / 2)))
    local leftX = 2
    local rightX = width - cardWidth - 1
    local junctionX = rightX - 2

    local h2Y = 5
    local etheneY = 10
    local bioY = 17

    renderMapCard(now, h2o2, leftX, h2Y, cardWidth)
    renderMapCard(now, biofuel, leftX, bioY, cardWidth)
    renderMapCard(now, ethene, rightX, etheneY, cardWidth)

    local h2Fill = type(h2o2.metrics) == "table" and h2o2.metrics.hydrogen or nil
    local bioFill =
        type(biofuel.ui) == "table" and biofuel.ui.outputFill
        or (type(biofuel.metrics) == "table" and biofuel.metrics.biofuel or nil)

    local h2Net = networkState(h2o2, now)
    local bioNet = networkState(biofuel, now)

    local h2Label =
        h2Net == "OFFLINE"
        and "H2 OFFLINE"
        or ("H2 " .. flowPercent(h2Fill))

    local bioLabel =
        bioNet == "OFFLINE"
        and "BIO OFFLINE"
        or ("BIOFUEL " .. flowPercent(bioFill))

    local h2Color = flowColor(h2o2, now, h2Fill, 0.10, 0.20)
    local bioColor = flowColor(biofuel, now, bioFill, 0.00, 0.05)

    drawFlow(leftX + cardWidth, junctionX, h2Y + 3, h2Label, h2Color)
    drawFlow(leftX + cardWidth, junctionX, bioY + 3, bioLabel, bioColor)

    for y = h2Y + 4, bioY + 2 do
        writeAt(junctionX, y, "|", colors.gray)
    end

    writeAt(junctionX, h2Y + 3, "+", h2Color)
    writeAt(junctionX, bioY + 3, "+", bioColor)

    local etheneInputY = etheneY + 3
    writeAt(junctionX, etheneInputY, "+>", colors.cyan)

    local liquidEtheneFill =
        type(ethene.ui) == "table" and ethene.ui.liquidEtheneFill
        or (type(ethene.metrics) == "table" and ethene.metrics.liquidEthene or nil)

    if etheneY + 8 <= height - 2 then
        local outputColor = flowColor(ethene, now, liquidEtheneFill, -1, -1)
        writeAt(rightX, etheneY + 8, "LIQ ETHENE  " .. flowPercent(liquidEtheneFill), outputColor)
    end

    local extras = {}
    for _, module in ipairs(list) do
        if module.id ~= "h2o2" and module.id ~= "biofuel" and module.id ~= "ethene" then
            table.insert(extras, module)
        end
    end

    if #extras > 0 then
        local extrasY = 26
        if extrasY <= height - 2 then
            writeAt(2, extrasY, "OTHER MODULES", colors.cyan)
            local y = extrasY + 1
            for _, module in ipairs(extras) do
                if y > height - 2 then break end
                local net = networkState(module, now)
                local runtime, runtimeColor = runtimeState(module, net == "OFFLINE")
                local text = ("[ %s ] %s"):format(tostring(module.label or module.id), runtime)
                writeAt(4, y, text, runtimeColor)

                moduleBounds[#moduleBounds + 1] = {
                    x1=4,
                    x2=math.min(width, 4 + #text - 1),
                    y1=y,
                    y2=y,
                    id=module.id,
                }
                y = y + 1
            end
        end
    end
end

local function renderMap(now, list)
    moduleBounds = {}
    backBounds = nil

    centered(3, "FACTORY FLOW MAP", colors.cyan)

    if modemCount == 0 then
        centered(6, "AUCUN MODEM REDNET", colors.red)
        return
    end

    if #list == 0 then
        centered(7, "EN ATTENTE DE MODULES...", colors.orange)
        return
    end

    local h2o2 = findModule(list, "h2o2")
    local biofuel = findModule(list, "biofuel")
    local ethene = findModule(list, "ethene")

    local connectedLayoutFits =
        width >= 54
        and height >= 25
        and h2o2 ~= nil
        and biofuel ~= nil
        and ethene ~= nil

    if connectedLayoutFits then
        renderConnectedMap(now, list, h2o2, biofuel, ethene)
    else
        renderGenericMap(now, list)
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


local function compact(value, unit)
    if type(value) ~= "number" then return "--" end
    local absValue = math.abs(value)
    if absValue >= 1e9 then return string.format("%.2f G%s", value / 1e9, unit or "") end
    if absValue >= 1e6 then return string.format("%.2f M%s", value / 1e6, unit or "") end
    if absValue >= 1e3 then return string.format("%.2f k%s", value / 1e3, unit or "") end
    return string.format("%.0f%s", value, unit or "")
end

local function machinePct(value)
    if type(value) ~= "number" then return "N/A" end
    return string.format("%.1f%%", math.max(0, math.min(1, value)) * 100)
end

local function shortName(name, maxLen)
    name = tostring(name or "")
    if #name <= maxLen then return name end
    return name:sub(1, math.max(1, maxLen - 3)) .. "..."
end

local function drawH2O2Bar(y, label, fill, color)
    fill = type(fill) == "number" and math.max(0, math.min(1, fill)) or 0
    local pctText = string.format("%5.1f%%", fill * 100)
    writeAt(2, y, label, colors.white)
    local barX = 14
    local barWidth = math.max(8, width - 28)
    local filled = math.floor(barWidth * fill + 0.5)
    writeAt(barX, y, string.rep(" ", barWidth), colors.white, colors.gray)
    if filled > 0 then writeAt(barX, y, string.rep(" ", filled), colors.black, color) end
    writeAt(barX + barWidth + 1, y, pctText, colors.white)
end

local function renderH2O2(now, module)
    h2o2TabOverviewBounds = nil
    h2o2TabMachinesBounds = nil
    h2o2ModeBounds = nil
    h2o2StartBounds = nil
    h2o2StopBounds = nil
    h2o2PrevBounds = nil
    h2o2NextBounds = nil
    h2o2LineBounds = {}
    h2o2MachineBounds = {}

    etheneTabOverviewBounds = nil
    etheneTabMachinesBounds = nil
    etheneModeBounds = nil
    etheneStartBounds = nil
    etheneStopBounds = nil
    ethenePrevBounds = nil
    etheneNextBounds = nil
    etheneLineBounds = {}
    etheneMachineBounds = {}
    biofuelModeBounds = nil
    biofuelStartBounds = nil
    biofuelStopBounds = nil
    etheneModeBounds = nil
    etheneStartBounds = nil
    etheneStopBounds = nil
    etheneLineBounds = {}

    local backLabel = "[ < MODULES ]"
    writeAt(2, 2, backLabel, colors.white, colors.gray)
    backBounds = {x1=2,x2=2+#backLabel-1,y1=2,y2=2}

    centered(1, "FACTORY H2/O2  v" .. tostring(module.version or "?"), colors.cyan)

    local overviewLabel = "[ OVERVIEW ]"
    local machinesLabel = "[ MACHINES ]"
    writeAt(18, 3, overviewLabel, colors.white, h2o2Page == "overview" and colors.blue or colors.gray)
    h2o2TabOverviewBounds = {x1=18,x2=18+#overviewLabel-1,y1=3,y2=3}
    local mx = 18 + #overviewLabel + 2
    writeAt(mx, 3, machinesLabel, colors.white, h2o2Page == "machines" and colors.blue or colors.gray)
    h2o2TabMachinesBounds = {x1=mx,x2=mx+#machinesLabel-1,y1=3,y2=3}

    local ui = type(module.ui) == "table" and module.ui or {}
    local mode = tostring(module.mode or "MANUAL")

    if h2o2Page == "machines" then
        centered(5, "CONTROLE MACHINES", colors.cyan)
        local machines = type(ui.machines) == "table" and ui.machines or {}
        local firstY = 7
        local rowsPerMachine = 3
        local machinesPerPage = math.max(1, math.floor((height - firstY - 4 + 1) / rowsPerMachine))
        local pageCount = math.max(1, math.ceil(#machines / machinesPerPage))
        if h2o2MachinePage > pageCount then h2o2MachinePage = pageCount end
        local startIndex = (h2o2MachinePage - 1) * machinesPerPage + 1
        local endIndex = math.min(#machines, startIndex + machinesPerPage - 1)
        local y = firstY

        if #machines == 0 then centered(8, "AUCUNE MACHINE", colors.orange) end

        for i=startIndex,endIndex do
            local machine = machines[i]
            local kindColor = machine.kind == "PUMP" and colors.lightBlue or colors.cyan
            local sColor = stateColor(machine.state)
            writeAt(2,y,tostring(machine.kind or "?"),kindColor)
            writeAt(8,y,shortName(machine.name,math.max(12,width-42)),colors.white)
            writeAt(math.max(30,width-26),y,tostring(machine.lineId or "UNASSIGNED"),colors.yellow)
            writeAt(math.max(42,width-14),y,tostring(machine.state or "?"),sColor)

            if mode == "AUTO" then
                writeAt(math.max(50,width-8),y,"[ AUTO ]",colors.lightGray,colors.gray)
            else
                local running = machine.state == "RUN"
                local label = running and "[ STOP ]" or "[ START ]"
                local bx = width - #label - 1
                writeAt(bx,y,label,running and colors.white or colors.black,running and colors.red or colors.lime)
                h2o2MachineBounds[#h2o2MachineBounds+1] = {
                    x1=bx,x2=bx+#label-1,y1=y,y2=y,
                    name=machine.name,targetMode=running and "HIGH" or "DISABLED"
                }
            end

            if machine.kind == "PUMP" then
                writeAt(8,y+1,"FLUID " .. machinePct(machine.fluidFill),colors.lightGray)
            else
                writeAt(8,y+1,("WATER %s   H2 %s   O2 %s"):format(
                    machinePct(machine.waterFill),
                    machinePct(machine.hydrogenFill),
                    machinePct(machine.oxygenFill)
                ),colors.lightGray)
                writeAt(8,y+2,("LEFT %s   RIGHT %s"):format(
                    tostring(machine.leftDumpMode or "N/A"),
                    tostring(machine.rightDumpMode or "N/A")
                ),colors.gray)
            end
            y=y+rowsPerMachine
        end

        local navY=height-2
        if h2o2MachinePage > 1 then
            writeAt(2,navY,"[ < ]",colors.white,colors.gray)
            h2o2PrevBounds={x1=2,x2=6,y1=navY,y2=navY}
        end
        centered(navY,("PAGE %d/%d"):format(h2o2MachinePage,pageCount),colors.lightGray)
        if h2o2MachinePage < pageCount then
            local label="[ > ]"
            local bx=width-#label-1
            writeAt(bx,navY,label,colors.white,colors.gray)
            h2o2NextBounds={x1=bx,x2=bx+#label-1,y1=navY,y2=navY}
        end
        return
    end

    centered(5, module.health == "OK" and "SYSTEME ONLINE" or "SYSTEME DEGRADE",
        module.health == "OK" and colors.lime or healthColor(module.health))
    centered(6, "PROCESS : " .. tostring(module.state or "?"), stateColor(module.state))

    local runtime, runtimeColor = runtimeState(module, false)
    writeAt(2,7,"RUNTIME : "..runtime,runtimeColor)
    local runtimeDetail = runtimeDetailText(module)
    if runtimeDetail then writeAt(math.max(24,width-24),7,runtimeDetail,colors.gray) end

    local metrics = type(module.metrics) == "table" and module.metrics or {}
    drawH2O2Bar(9,"WATER",metrics.water,colors.blue)
    drawH2O2Bar(11,"HYDROGEN",metrics.hydrogen,colors.lightBlue)
    drawH2O2Bar(13,"OXYGEN",metrics.oxygen,colors.cyan)

    writeAt(2,15,("Separators : %s actifs | %s detectes"):format(
        tostring(ui.separatorRunning or "?"), tostring(ui.separatorResponding or "?")),colors.lightGray)
    writeAt(2,16,"Usage      : " .. compact(ui.usage," FE/t"),colors.white)
    if type(ui.maxEnergy) == "number" and ui.maxEnergy > 0 then
        writeAt(2,17,("Sep energy : %s / %s"):format(compact(ui.energy," FE"),compact(ui.maxEnergy," FE")),colors.white)
    end

    local modeY=math.max(20,height-9)
    writeAt(2,modeY,"MODE :",colors.lightGray)
    writeAt(9,modeY,mode,modeColor(mode))
    if mode == "AUTO" then
        writeAt(16,modeY,("TARGET %s/%s"):format(tostring(ui.targetLines or 0),tostring(module.totalLines or 0)),colors.white)
    end
    local modeLabel = mode == "AUTO" and "[ MANUAL ]" or "[ AUTO ]"
    local modeX=width-#modeLabel-1
    writeAt(modeX,modeY,modeLabel,colors.white,mode=="AUTO" and colors.blue or colors.lime)
    h2o2ModeBounds={x1=modeX,x2=modeX+#modeLabel-1,y1=modeY,y2=modeY}

    local titleY=modeY+2
    writeAt(2,titleY,"LINES",colors.cyan)
    if module.reason then writeAt(10,titleY,tostring(module.reason),colors.lightGray) end

    local lines=type(ui.lines)=="table" and ui.lines or {}
    local y=titleY+1
    for _,line in ipairs(lines) do
        writeAt(4,y,tostring(line.id),colors.white)
        writeAt(16,y,tostring(line.state),stateColor(line.state))
        if mode=="AUTO" then
            writeAt(28,y,"[ AUTO ]",colors.lightGray,colors.gray)
        else
            local running=line.state=="RUN"
            local label=running and "[ STOP ]" or "[ START ]"
            writeAt(28,y,label,running and colors.white or colors.black,running and colors.red or colors.lime)
            h2o2LineBounds[#h2o2LineBounds+1]={
                x1=28,x2=28+#label-1,y1=y,y2=y,
                id=line.id,targetMode=running and "HIGH" or "DISABLED"
            }
        end
        y=y+1
    end

    local controlsY=math.max(19,height-2)
    if mode=="AUTO" then
        writeAt(2,controlsY,"AUTO ACTIF - CONTROLES MANUELS VERROUILLES",colors.lightGray)
    else
        local startLabel="[ START ALL ]"
        local stopLabel="[ STOP ALL ]"
        writeAt(2,controlsY,startLabel,colors.black,colors.lime)
        h2o2StartBounds={x1=2,x2=2+#startLabel-1,y1=controlsY,y2=controlsY}
        local sx=2+#startLabel+2
        writeAt(sx,controlsY,stopLabel,colors.white,colors.red)
        h2o2StopBounds={x1=sx,x2=sx+#stopLabel-1,y1=controlsY,y2=controlsY}
    end
end

local function sendH2O2Control(scope,target,targetMode,label)
    os.queueEvent("factory_control_request",scope,target or "",targetMode,label or "SUPERVISOR")
end


local function renderBiofuel(now, module)
    biofuelModeBounds = nil
    biofuelStartBounds = nil
    biofuelStopBounds = nil

    local backLabel = "[ < MODULES ]"
    writeAt(2,2,backLabel,colors.white,colors.gray)
    backBounds={x1=2,x2=2+#backLabel-1,y1=2,y2=2}

    centered(1,"FACTORY BIOFUEL  v"..tostring(module.version or "?"),colors.cyan)

    centered(4,module.health=="OK" and "SYSTEME ONLINE" or "SYSTEME INCOMPLET",
        module.health=="OK" and colors.lime or healthColor(module.health))

    local ui=type(module.ui)=="table" and module.ui or {}
    local mode=tostring(module.mode or "MANUAL")
    local processState=tostring(module.state or "IDLE")
    centered(5,"PROCESS : "..processState,stateColor(processState))

    local runtime, runtimeColor = runtimeState(module, false)
    writeAt(3,6,"RUNTIME : "..runtime,runtimeColor)
    local runtimeDetail = runtimeDetailText(module)
    if runtimeDetail then writeAt(math.max(24,width-24),6,runtimeDetail,colors.gray) end

    writeAt(3,8,"INPUT BUFFER",colors.yellow)
    writeAt(5,9,tostring(ui.inputItem or "EMPTY"):gsub("^.-:",""):gsub("_"," "):upper(),colors.white)
    writeAt(5,10,("COUNT : %s / %s  (%s)"):format(
        tostring(ui.inputCount or 0),
        tostring(ui.inputCapacity or "?"),
        type(ui.inputFill)=="number" and string.format("%.1f%%",ui.inputFill*100) or "N/A"
    ),colors.lightGray)

    writeAt(3,13,"CRUSHING FACTORY",colors.cyan)
    local crusherState=tostring(ui.crusherState or "UNKNOWN")
    writeAt(5,14,"STATE  : "..crusherState,stateColor(crusherState))
    local energyText="ENERGY : N/A"
    if type(ui.energy)=="number" and type(ui.maxEnergy)=="number" then
        energyText=("ENERGY : %s / %s"):format(compact(ui.energy," FE"),compact(ui.maxEnergy," FE"))
    elseif type(ui.energyFill)=="number" then
        energyText=("ENERGY : %.1f%%"):format(ui.energyFill*100)
    end
    writeAt(5,15,energyText,colors.lightGray)
    writeAt(5,16,"USAGE  : "..compact(ui.energyUsage," FE/t"),colors.lightGray)

    writeAt(3,19,"BIOFUEL BUFFER",colors.green)
    writeAt(5,20,"BIO FUEL",colors.white)
    writeAt(5,21,("COUNT : %s / %s  (%s)"):format(
        tostring(ui.outputCount or 0),
        tostring(ui.outputCapacity or "?"),
        type(ui.outputFill)=="number" and string.format("%.1f%%",ui.outputFill*100) or "N/A"
    ),colors.lightGray)

    if ui.autoConfigured then
        writeAt(5,22,("TARGET: %s | RESUME: %s"):format(
            tostring(ui.targetItems or "?"),tostring(ui.resumeItems or "?")),colors.gray)
    else
        writeAt(5,22,"TARGET: A RENSEIGNER",colors.orange)
    end

    local modeY=math.max(24,height-6)
    writeAt(3,modeY,"MODE :",colors.lightGray)
    writeAt(10,modeY,mode,modeColor(mode))
    local modeLabel=mode=="AUTO" and "[ MANUAL ]" or "[ AUTO ]"
    local mx=width-#modeLabel-1
    writeAt(mx,modeY,modeLabel,colors.white,mode=="AUTO" and colors.blue or colors.lime)
    biofuelModeBounds={x1=mx,x2=mx+#modeLabel-1,y1=modeY,y2=modeY}

    writeAt(3,modeY+2,"STATUS :",colors.gray)
    local reason=tostring(module.reason or "-")
    local reasonColor=colors.lightGray
    if reason:find("FAULT",1,true) then reasonColor=colors.red
    elseif reason:find("HOLD",1,true) or reason:find("STOP",1,true) then reasonColor=colors.orange
    elseif reason:find("PRODUCTION",1,true) or reason:find("RUN",1,true) then reasonColor=colors.lime end
    writeAt(12,modeY+2,reason,reasonColor)

    local controlY=height-2
    if mode=="AUTO" then
        writeAt(3,controlY,"AUTO ACTIF - CONTROLE MANUEL VERROUILLE",colors.lightGray)
    else
        local startLabel="[ START ]"
        local stopLabel="[ STOP ]"
        writeAt(3,controlY,startLabel,colors.black,colors.lime)
        biofuelStartBounds={x1=3,x2=3+#startLabel-1,y1=controlY,y2=controlY}
        local sx=3+#startLabel+2
        writeAt(sx,controlY,stopLabel,colors.white,colors.red)
        biofuelStopBounds={x1=sx,x2=sx+#stopLabel-1,y1=controlY,y2=controlY}
    end
end

local function sendBiofuelControl(action,targetMode)
    os.queueEvent("factory_biofuel_control",action,targetMode)
end

local function renderEthene(now, module)
    etheneTabOverviewBounds = nil
    etheneTabMachinesBounds = nil
    etheneModeBounds = nil
    etheneStartBounds = nil
    etheneStopBounds = nil
    ethenePrevBounds = nil
    etheneNextBounds = nil
    etheneLineBounds = {}
    etheneMachineBounds = {}

    local backLabel = "[ < MODULES ]"
    writeAt(2,2,backLabel,colors.white,colors.gray)
    backBounds={x1=2,x2=2+#backLabel-1,y1=2,y2=2}

    centered(1,"FACTORY ETHENE  v"..tostring(module.version or "?"),colors.cyan)

    local overviewLabel="[ OVERVIEW ]"
    local machinesLabel="[ MACHINES ]"
    writeAt(18,3,overviewLabel,colors.white,ethenePage=="overview" and colors.blue or colors.gray)
    etheneTabOverviewBounds={x1=18,x2=18+#overviewLabel-1,y1=3,y2=3}
    local tx=18+#overviewLabel+2
    writeAt(tx,3,machinesLabel,colors.white,ethenePage=="machines" and colors.blue or colors.gray)
    etheneTabMachinesBounds={x1=tx,x2=tx+#machinesLabel-1,y1=3,y2=3}

    local ui=type(module.ui)=="table" and module.ui or {}
    local mode=tostring(module.mode or "AUTO")

    if ethenePage=="machines" then
        centered(5,"CONTROLE MACHINES",colors.cyan)

        local machines=type(ui.machines)=="table" and ui.machines or {}
        local firstY=7
        local rowsPerMachine=4
        local machinesPerPage=math.max(1,math.floor((height-firstY-4+1)/rowsPerMachine))
        local pageCount=math.max(1,math.ceil(#machines/machinesPerPage))
        if etheneMachinePage>pageCount then etheneMachinePage=pageCount end

        local startIndex=(etheneMachinePage-1)*machinesPerPage+1
        local endIndex=math.min(#machines,startIndex+machinesPerPage-1)
        local y=firstY

        if #machines==0 then centered(8,"AUCUNE MACHINE",colors.orange) end

        for i=startIndex,endIndex do
            local machine=machines[i]
            local kind=tostring(machine.kind or "?")
            local kindColor=kind=="PUMP" and colors.lightBlue or colors.cyan
            local state=tostring(machine.state or "?")
            if kind=="CONDENS" and machine.hold then state="HOLD" end

            writeAt(2,y,kind,kindColor)
            writeAt(8,y,shortName(machine.name,math.max(12,width-42)),colors.white)
            writeAt(math.max(30,width-26),y,tostring(machine.lineId or "UNASSIGNED"),colors.yellow)
            writeAt(math.max(42,width-14),y,state,stateColor(state))

            if mode=="AUTO" then
                writeAt(math.max(50,width-8),y,"[ AUTO ]",colors.lightGray,colors.gray)
            else
                local running=state=="RUN"
                local label=running and "[ STOP ]" or "[ START ]"
                local bx=width-#label-1
                writeAt(bx,y,label,running and colors.white or colors.black,
                    running and colors.red or colors.lime)
                etheneMachineBounds[#etheneMachineBounds+1]={
                    x1=bx,x2=bx+#label-1,y1=y,y2=y,
                    name=machine.name,targetMode=running and "HIGH" or "DISABLED"
                }
            end

            if kind=="PUMP" then
                local fluid=machinePct(machine.fluidFill)
                local water=machinePct(machine.waterFill)
                writeAt(8,y+1,("WATER %s   PUMP FLUID %s"):format(water,fluid),colors.lightGray)

                local energyText="ENERGY N/A"
                if type(machine.energy)=="number" and type(machine.maxEnergy)=="number" then
                    energyText=("ENERGY %s / %s"):format(
                        compact(machine.energy," FE"),
                        compact(machine.maxEnergy," FE")
                    )
                end
                writeAt(8,y+2,energyText,colors.gray)
                writeAt(8,y+3,"USAGE "..compact(machine.energyUsage," FE/t"),colors.gray)

            elseif kind=="CONDENS" then
                writeAt(8,y+1,("ETHENE GAS %s   LIQUID %s"):format(
                    machinePct(machine.inputFill),
                    machinePct(machine.liquidFill)
                ),colors.lightGray)

                local energyText="ENERGY N/A"
                if type(machine.energy)=="number" and type(machine.maxEnergy)=="number" then
                    energyText=("ENERGY %s / %s"):format(
                        compact(machine.energy," FE"),
                        compact(machine.maxEnergy," FE")
                    )
                end
                writeAt(8,y+2,energyText,colors.gray)
                writeAt(8,y+3,"USAGE "..compact(machine.energyUsage," FE/t"),colors.gray)

            else
                writeAt(8,y+1,("WATER %s   H2 %s   ETHENE %s"):format(
                    machinePct(machine.waterFill),
                    machinePct(machine.hydrogenFill),
                    machinePct(machine.etheneFill)
                ),colors.lightGray)

                local inputLabel=tostring(machine.inputItemName or "EMPTY")
                    :gsub("^.-:",""):gsub("_"," "):upper()
                writeAt(8,y+2,("BIOFUEL %s x%s   SUB %s"):format(
                    inputLabel,
                    tostring(machine.inputItemCount or 0),
                    tostring(machine.substrateCount or 0)
                ),colors.gray)

                local energyText="ENERGY N/A"
                if type(machine.energy)=="number" and type(machine.maxEnergy)=="number" then
                    energyText=("ENERGY %s / %s | %s"):format(
                        compact(machine.energy," FE"),
                        compact(machine.maxEnergy," FE"),
                        compact(machine.energyUsage," FE/t")
                    )
                end
                writeAt(8,y+3,energyText,colors.gray)
            end

            y=y+rowsPerMachine
        end

        local navY=height-2
        if etheneMachinePage>1 then
            writeAt(2,navY,"[ < ]",colors.white,colors.gray)
            ethenePrevBounds={x1=2,x2=6,y1=navY,y2=navY}
        end
        centered(navY,("PAGE %d/%d"):format(etheneMachinePage,pageCount),colors.lightGray)
        if etheneMachinePage<pageCount then
            local label="[ > ]"
            local bx=width-#label-1
            writeAt(bx,navY,label,colors.white,colors.gray)
            etheneNextBounds={x1=bx,x2=bx+#label-1,y1=navY,y2=navY}
        end
        return
    end

    centered(5,module.health=="FAULT" and "SYSTEME INCOMPLET" or "SYSTEME ONLINE",
        module.health=="FAULT" and colors.red or healthColor(module.health))
    centered(6,"PROCESS : "..tostring(module.state or "?"),stateColor(module.state))

    local runtime,runtimeColor=runtimeState(module,false)
    writeAt(3,7,"RUNTIME : "..runtime,runtimeColor)
    local runtimeDetail=runtimeDetailText(module)
    if runtimeDetail then writeAt(math.max(24,width-24),7,runtimeDetail,colors.gray) end

    drawH2O2Bar(9,"ETHENE GAS",ui.etheneFill,colors.green)
    drawH2O2Bar(11,"LIQ ETHENE",ui.liquidEtheneFill,colors.lime)
    drawH2O2Bar(13,"HYDROGEN",ui.hydrogenFill,colors.lightBlue)

    writeAt(3,15,("BIOFUEL   : %s / %s  (%s)"):format(
        tostring(ui.biofuelCount or 0),
        tostring(ui.biofuelCapacity or "?"),
        type(ui.biofuelFill)=="number" and string.format("%.1f%%",ui.biofuelFill*100) or "N/A"
    ),colors.yellow)

    local substrateTotal=tonumber(ui.substrateTotal) or 0
    local substrateColor=substrateTotal>=96 and colors.orange or colors.lightGray
    writeAt(3,16,"SUBSTRATE : "..tostring(substrateTotal).." | OUTPUT QE",substrateColor)

    local conversionState=tostring(ui.conversionState or "N/A")
    if ui.conversionHold then conversionState="HOLD" end
    writeAt(3,17,"CONVERSION: "..conversionState,stateColor(conversionState))

    local lines=type(ui.lines)=="table" and ui.lines or {}

    writeAt(3,19,"LINES",colors.cyan)
    local y=20
    for _,line in ipairs(lines) do
        writeAt(4,y,tostring(line.id),colors.white)
        local lineDisplayState=tostring(line.state)
        if (tonumber(line.substrateCount) or 0)>=64 then lineDisplayState="HOLD" end
        writeAt(14,y,lineDisplayState,stateColor(lineDisplayState))
        writeAt(24,y,("WATER %s"):format(
            type(line.waterFill)=="number" and string.format("%.0f%%",line.waterFill*100) or "N/A"
        ),colors.blue)
        writeAt(38,y,"SUB "..tostring(line.substrateCount or 0),
            (line.substrateCount or 0)>=48 and colors.orange or colors.lightGray)

        if mode=="MANUAL" then
            local running=line.state=="RUN"
            local label=running and "[ STOP ]" or "[ START ]"
            local bx=width-#label-1
            writeAt(bx,y,label,running and colors.white or colors.black,
                running and colors.red or colors.lime)
            etheneLineBounds[#etheneLineBounds+1]={
                x1=bx,x2=bx+#label-1,y1=y,y2=y,
                id=line.id,targetMode=running and "HIGH" or "DISABLED"
            }
        end
        y=y+2
    end

    local modeY=math.max(25,height-6)
    writeAt(3,modeY,"MODE :",colors.lightGray)
    writeAt(10,modeY,mode,modeColor(mode))
    if mode=="AUTO" then
        writeAt(18,modeY,("TARGET %s/%s"):format(
            tostring(ui.targetLines or 0),tostring(module.totalLines or 0)),colors.white)
    end

    local modeLabel=mode=="AUTO" and "[ MANUAL ]" or "[ AUTO ]"
    local mx=width-#modeLabel-1
    writeAt(mx,modeY,modeLabel,colors.white,mode=="AUTO" and colors.blue or colors.lime)
    etheneModeBounds={x1=mx,x2=mx+#modeLabel-1,y1=modeY,y2=modeY}

    writeAt(3,modeY+2,"STATUS :",colors.gray)
    writeAt(12,modeY+2,tostring(module.reason or "-"),
        module.health=="FAULT" and colors.red
        or tostring(module.reason or ""):find("HOLD",1,true) and colors.orange
        or colors.lightGray)

    local controlY=height-2
    if mode=="AUTO" then
        writeAt(3,controlY,"AUTO ACTIF - CONTROLES MANUELS VERROUILLES",colors.lightGray)
    else
        local startLabel="[ START ALL ]"
        local stopLabel="[ STOP ALL ]"
        writeAt(3,controlY,startLabel,colors.black,colors.lime)
        etheneStartBounds={x1=3,x2=3+#startLabel-1,y1=controlY,y2=controlY}
        local sx=3+#startLabel+2
        writeAt(sx,controlY,stopLabel,colors.white,colors.red)
        etheneStopBounds={x1=sx,x2=sx+#stopLabel-1,y1=controlY,y2=controlY}
    end
end

local function sendEtheneControl(action,target,targetMode)
    os.queueEvent("factory_ethene_control",action,target or "",targetMode)
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

    -- Clear the physical monitor too. The Supervisor renders through a window,
    -- and switching between views with different title lengths can otherwise
    -- leave stale characters visible behind that window.
    physicalMonitor.setBackgroundColor(colors.black)
    physicalMonitor.setTextColor(colors.white)
    physicalMonitor.clear()

    monitor.setVisible(false)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    updateBounds = nil
    backBounds = nil
    moduleBounds = {}
    h2o2TabOverviewBounds = nil
    h2o2TabMachinesBounds = nil
    h2o2ModeBounds = nil
    h2o2StartBounds = nil
    h2o2StopBounds = nil
    h2o2PrevBounds = nil
    h2o2NextBounds = nil
    h2o2LineBounds = {}
    h2o2MachineBounds = {}

    if currentView == "detail" and selectedModuleId == "h2o2" and modules.h2o2 then
        renderH2O2(now, modules.h2o2)
    elseif currentView == "detail" and selectedModuleId == "biofuel" and modules.biofuel then
        renderBiofuel(now, modules.biofuel)
    elseif currentView == "detail" and selectedModuleId == "ethene" and modules.ethene then
        renderEthene(now, modules.ethene)
    elseif currentView == "detail" then
        renderDetail(now)
    else
        centered(1, "FACTORY SUPERVISOR  v" .. PROGRAM_VERSION, colors.cyan)
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

local function moduleEtheneLoop()
    runModuleProcess(MODULE_PROGRAMS[3])
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
                h2o2Page = "overview"
                ethenePage = "overview"

            else
                local handled = false

                if currentView == "map" then
                    for _, bounds in ipairs(moduleBounds) do
                        if inside(bounds, x, y) then
                            selectedModuleId = bounds.id
                            currentView = "detail"

                            -- A sleeping module refreshes its peripheral data immediately
                            -- when the operator opens it.
                            os.queueEvent("factory_module_wake", bounds.id, "OPEN")

                            handled = true
                            break
                        end
                    end
                elseif currentView == "detail" and selectedModuleId == "h2o2" then
                    if inside(h2o2TabOverviewBounds,x,y) then
                        h2o2Page="overview"
                        handled=true
                    elseif inside(h2o2TabMachinesBounds,x,y) then
                        h2o2Page="machines"
                        handled=true
                    elseif inside(h2o2PrevBounds,x,y) then
                        h2o2MachinePage=math.max(1,h2o2MachinePage-1)
                        handled=true
                    elseif inside(h2o2NextBounds,x,y) then
                        h2o2MachinePage=h2o2MachinePage+1
                        handled=true
                    elseif inside(h2o2ModeBounds,x,y) then
                        os.queueEvent("factory_h2o2_mode_toggle")
                        handled=true
                    elseif inside(h2o2StartBounds,x,y) then
                        sendH2O2Control("all","","DISABLED","START ALL")
                        handled=true
                    elseif inside(h2o2StopBounds,x,y) then
                        sendH2O2Control("all","","HIGH","STOP ALL")
                        handled=true
                    else
                        for _,button in ipairs(h2o2LineBounds) do
                            if inside(button,x,y) then
                                sendH2O2Control("line",button.id,button.targetMode,"LINE "..tostring(button.id))
                                handled=true
                                break
                            end
                        end
                        if not handled then
                            for _,button in ipairs(h2o2MachineBounds) do
                                if inside(button,x,y) then
                                    sendH2O2Control("machine",button.name,button.targetMode,"MACHINE")
                                    handled=true
                                    break
                                end
                            end
                        end
                    end
                elseif currentView == "detail" and selectedModuleId == "biofuel" then
                    if inside(biofuelModeBounds,x,y) then
                        sendBiofuelControl("toggle_mode")
                        handled=true
                    elseif inside(biofuelStartBounds,x,y) then
                        sendBiofuelControl("crusher","DISABLED")
                        handled=true
                    elseif inside(biofuelStopBounds,x,y) then
                        sendBiofuelControl("crusher","HIGH")
                        handled=true
                    end

                elseif currentView == "detail" and selectedModuleId == "ethene" then
                    if inside(etheneTabOverviewBounds,x,y) then
                        ethenePage="overview"
                        handled=true
                    elseif inside(etheneTabMachinesBounds,x,y) then
                        ethenePage="machines"
                        handled=true
                    elseif inside(ethenePrevBounds,x,y) then
                        etheneMachinePage=math.max(1,etheneMachinePage-1)
                        handled=true
                    elseif inside(etheneNextBounds,x,y) then
                        etheneMachinePage=etheneMachinePage+1
                        handled=true
                    elseif inside(etheneModeBounds,x,y) then
                        sendEtheneControl("toggle_mode")
                        handled=true
                    elseif inside(etheneStartBounds,x,y) then
                        sendEtheneControl("all","","DISABLED")
                        handled=true
                    elseif inside(etheneStopBounds,x,y) then
                        sendEtheneControl("all","","HIGH")
                        handled=true
                    else
                        for _,button in ipairs(etheneLineBounds) do
                            if inside(button,x,y) then
                                sendEtheneControl("line",button.id,button.targetMode)
                                handled=true
                                break
                            end
                        end

                        if not handled then
                            for _,button in ipairs(etheneMachineBounds) do
                                if inside(button,x,y) then
                                    sendEtheneControl("machine",button.name,button.targetMode)
                                    handled=true
                                    break
                                end
                            end
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

parallel.waitForAny(statusLoop, uiLoop, refreshLoop, moduleH2O2Loop, moduleBiofuelLoop, moduleEtheneLoop)
