local PROGRAM_VERSION = "0.3.2"
local args = { ... }
local HEADLESS = args[1] == "--headless"
local CONFIG_PATH = "/config/factory_biofuel.lua"
local UPDATER_PATH = "/programs/factory/lib/updater.lua"
local STATUS_BUS_PATH = "/programs/factory/lib/status_bus.lua"
local UPDATE_MANIFEST = "programs/factory/biofuel_update_manifest.lua"

local defaults = {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,

    inputBarrel = "sophisticatedstorage:barrel_0",
    crusher = "ultimateCrushingFactory_0",
    outputBarrel = "sophisticatedstorage:barrel_1",
    stopMode = "HIGH",

    auto = {
        -- L'AUTO reste disponible mais ne peut pas determiner "plein"
        -- tant que targetItems n'est pas renseigne.
        targetItems = 270336,
        resumeItems = 216269,
        checkSeconds = 2,
    },

    status = {
        publishSeconds = 2,
        id = "biofuel",
        label = "BIOFUEL",
        type = "process",
    },
}

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then return defaults end

    local ok, cfg = pcall(dofile, CONFIG_PATH)
    if not ok or type(cfg) ~= "table" then return defaults end

    local function mergeMissing(target, source)
        for key, value in pairs(source) do
            if target[key] == nil then
                target[key] = value
            elseif type(target[key]) == "table" and type(value) == "table" then
                mergeMissing(target[key], value)
            end
        end
    end

    mergeMissing(cfg, defaults)
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

local monitor = nil
local monitorName = nil
local width, height = 0, 0

if not HEADLESS then
    monitor, monitorName = getMonitor()
    monitor.setTextScale(config.textScale)
    width, height = monitor.getSize()
end

local updateBounds = nil
local updateConfirmUntil = 0
local updateMessage = nil
local updateMessageUntil = 0
local updateInProgress = false
local dataCache = nil

local operatingMode = "AUTO"
local autoState = {
    hold = false,
    reason = "AUTO INIT",
    lastTick = 0,
}

local function safeCall(device, method, ...)
    if not device or type(device[method]) ~= "function" then return nil end

    local ok, result = pcall(device[method], ...)
    if ok then return result end

    return nil
end

local function writeAt(x, y, text, fg, bg)
    if y < 1 or y > height then return end

    text = tostring(text or "")
    if x < 1 then x = 1 end
    if x > width then return end

    local maxLen = width - x + 1
    if #text > maxLen then
        text = text:sub(1, maxLen)
    end

    monitor.setCursorPos(x, y)
    monitor.setTextColor(fg or colors.white)
    monitor.setBackgroundColor(bg or colors.black)
    monitor.write(text)
end

local function centered(y, text, fg, bg)
    text = tostring(text or "")
    local x = math.max(1, math.floor((width - #text) / 2) + 1)
    writeAt(x, y, text, fg, bg)
end

local function compact(value, suffix)
    if type(value) ~= "number" then return "N/A" end

    local abs = math.abs(value)
    if abs >= 1000000000 then
        return ("%.2f G%s"):format(value / 1000000000, suffix or "")
    elseif abs >= 1000000 then
        return ("%.2f M%s"):format(value / 1000000, suffix or "")
    elseif abs >= 1000 then
        return ("%.2f k%s"):format(value / 1000, suffix or "")
    end

    return ("%.0f%s"):format(value, suffix or "")
end

local function itemLabel(name)
    if type(name) ~= "string" or name == "" then return "EMPTY" end

    local label = name:match(":(.+)$") or name
    label = label:gsub("_", " ")
    return label:upper()
end

local function summarizeBarrel(name)
    if not peripheral.isPresent(name) then
        return {
            present = false,
            itemName = nil,
            count = 0,
            stacks = 0,
        }
    end

    local dev = peripheral.wrap(name)
    local items = safeCall(dev, "list")

    if type(items) ~= "table" then
        return {
            present = true,
            itemName = nil,
            count = 0,
            stacks = 0,
            readable = false,
        }
    end

    local total = 0
    local stacks = 0
    local dominantName = nil
    local dominantCount = -1
    local distinct = {}

    for _, item in pairs(items) do
        if type(item) == "table" then
            local count = tonumber(item.count) or 0
            local nameValue = item.name

            total = total + count
            stacks = stacks + 1

            if nameValue then
                distinct[nameValue] = true
                if count > dominantCount then
                    dominantCount = count
                    dominantName = nameValue
                end
            end
        end
    end

    local distinctCount = 0
    for _ in pairs(distinct) do distinctCount = distinctCount + 1 end

    return {
        present = true,
        readable = true,
        itemName = dominantName,
        count = total,
        stacks = stacks,
        mixed = distinctCount > 1,
    }
end

local function collectData()
    local input = summarizeBarrel(config.inputBarrel)
    local output = summarizeBarrel(config.outputBarrel)

    local crusherPresent = peripheral.isPresent(config.crusher)
    local crusher = crusherPresent and peripheral.wrap(config.crusher) or nil

    local redstoneMode = safeCall(crusher, "getRedstoneMode")
    local crusherState

    if not crusherPresent then
        crusherState = "ABSENT"
    elseif redstoneMode == "DISABLED" then
        crusherState = "RUN"
    elseif redstoneMode == config.stopMode then
        crusherState = "STOP"
    elseif redstoneMode == nil then
        crusherState = "UNKNOWN"
    else
        crusherState = "WARN"
    end

    return {
        input = input,
        output = output,

        crusherPresent = crusherPresent,
        crusherState = crusherState,
        energy = safeCall(crusher, "getEnergy"),
        maxEnergy = safeCall(crusher, "getMaxEnergy"),
        energyFill = safeCall(crusher, "getEnergyFilledPercentage"),
        energyUsage = safeCall(crusher, "getEnergyUsage"),

        online =
            input.present
            and output.present
            and crusherPresent,
    }
end

local function setCrusherMode(targetMode)
    if not peripheral.isPresent(config.crusher) then
        return false, "CRUSHER ABSENT"
    end

    local crusher = peripheral.wrap(config.crusher)
    if not crusher or type(crusher.setRedstoneMode) ~= "function" then
        return false, "CRUSHER NON CONTROLABLE"
    end

    local ok, err = pcall(crusher.setRedstoneMode, targetMode)
    if not ok then return false, tostring(err) end
    return true, targetMode
end

local function autoConfigured()
    return type(config.auto.targetItems) == "number" and config.auto.targetItems > 0
end

local function resumeTarget()
    if type(config.auto.resumeItems) == "number" and config.auto.resumeItems >= 0 then
        return math.min(config.auto.resumeItems, config.auto.targetItems)
    end
    return math.floor(config.auto.targetItems * 0.80)
end

local function applyAuto(data)
    if operatingMode ~= "AUTO" then return end

    if not autoConfigured() then
        autoState.reason = "WAIT TARGET CONFIG"
        return
    end

    local outputCount = tonumber(data.output.count) or 0
    local target = config.auto.targetItems
    local resume = resumeTarget()

    if autoState.hold then
        if outputCount <= resume then
            autoState.hold = false
        else
            autoState.reason = ("BUFFER HOLD %d/%d"):format(outputCount, target)
            if data.crusherState == "RUN" then pcall(setCrusherMode, config.stopMode) end
            return
        end
    end

    if outputCount >= target then
        autoState.hold = true
        autoState.reason = ("BUFFER FULL %d/%d"):format(outputCount, target)
        pcall(setCrusherMode, config.stopMode)
        return
    end

    if (tonumber(data.input.count) or 0) <= 0 then
        autoState.reason = "HOLD INPUT EMPTY"
        pcall(setCrusherMode, config.stopMode)
        return
    end

    autoState.reason = ("PRODUCTION %d/%d"):format(outputCount, target)
    if data.crusherState ~= "RUN" then pcall(setCrusherMode, "DISABLED") end
end

local function ratio(value, maximum)
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
        return nil
    end

    return math.max(0, math.min(1, value / maximum))
end

local function buildModuleStatus(data)
    local health = data.online and "OK" or "FAULT"
    local state = "IDLE"
    local alarms = {}

    if not data.online then
        state = "STOP"
        table.insert(alarms, "CRITICAL PERIPHERAL MISSING")
    elseif data.crusherState == "RUN" then
        state = "RUN"
    elseif data.crusherState == "STOP" then
        state = "STOP"
    elseif data.crusherState == "UNKNOWN" or data.crusherState == "WARN" then
        state = "IDLE"
    end

    local inputText =
        itemLabel(data.input.itemName) .. " x" .. tostring(data.input.count or 0)
    local outputText =
        "BIO FUEL x" .. tostring(data.output.count or 0)

    return {
        contract = 1,
        id = config.status.id,
        label = config.status.label,
        type = config.status.type,
        version = PROGRAM_VERSION,

        mode = operatingMode,
        state = state,
        health = health,
        runtimeState =
            health == "FAULT" and "FAULT"
            or (operatingMode == "AUTO" and autoState.hold and "IDLE")
            or (state == "RUN" and "ACTIVE" or "IDLE"),
        reason = operatingMode == "AUTO"
            and autoState.reason
            or (data.crusherState == "RUN" and "MANUAL RUN"
                or data.crusherState == "STOP" and "MANUAL STOP"
                or "MANUAL " .. tostring(data.crusherState)),

        metrics = {
            energy = data.energyFill,
        },

        ui = {
            inputCount = data.input.count,
            inputItem = data.input.itemName,
            outputCount = data.output.count,
            crusherState = data.crusherState,
            energy = data.energy,
            maxEnergy = data.maxEnergy,
            energyFill = data.energyFill,
            energyUsage = data.energyUsage,
            targetItems = config.auto.targetItems,
            resumeItems = autoConfigured() and resumeTarget() or nil,
            autoConfigured = autoConfigured(),
        },

        details = {
            { label = "INPUT", value = inputText },
            { label = "OUTPUT", value = outputText },
            { label = "CRUSHER", value = tostring(data.crusherState) },
            {
                label = "ENERGY",
                value = type(data.energyFill) == "number"
                    and ("%.1f%%"):format(data.energyFill * 100)
                    or "N/A",
            },
            {
                label = "USAGE",
                value = compact(data.energyUsage, " FE/t"),
            },
        },

        alarms = alarms,
    }
end

local function loadStatusBus()
    if not fs.exists(STATUS_BUS_PATH) then return nil end

    local ok, bus = pcall(dofile, STATUS_BUS_PATH)
    if not ok or type(bus) ~= "table" then return nil end

    pcall(bus.open)
    return bus
end

local function drawUpdateButton(now)
    local label

    if updateInProgress then
        label = "[ MAJ... ]"
    elseif now < updateConfirmUntil then
        label = "[ CONFIRMER ]"
    else
        label = "[ MAJ ]"
    end

    local x = math.max(1, width - #label - 1)
    writeAt(
        x,
        2,
        label,
        updateInProgress and colors.lightGray or colors.white,
        updateInProgress and colors.gray or colors.blue
    )

    updateBounds = {
        x1 = x,
        x2 = x + #label - 1,
        y1 = 2,
        y2 = 2,
    }
end

local function renderBarrel(y, title, barrel, accent)
    writeAt(3, y, title, accent)

    if not barrel.present then
        writeAt(5, y + 1, "ABSENT", colors.red)
        return
    end

    local label = barrel.mixed and "MIXED" or itemLabel(barrel.itemName)
    writeAt(5, y + 1, label, barrel.count > 0 and colors.white or colors.lightGray)
    writeAt(5, y + 2, "COUNT : " .. tostring(barrel.count), colors.lightGray)
end

local function render()
    local now = os.epoch("utc") / 1000
    local data = dataCache

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    centered(1, "FACTORY BIOFUEL  v" .. PROGRAM_VERSION, colors.cyan)
    drawUpdateButton(now)

    if not data then
        centered(6, "INITIALISATION...", colors.orange)
        return
    end

    centered(
        4,
        data.online and "SYSTEME ONLINE" or "SYSTEME INCOMPLET",
        data.online and colors.lime or colors.red
    )

    renderBarrel(7, "INPUT BUFFER", data.input, colors.yellow)

    writeAt(3, 12, "CRUSHING FACTORY", colors.cyan)

    local stateColor = colors.orange
    if data.crusherState == "RUN" then stateColor = colors.lime end
    if data.crusherState == "ABSENT" then stateColor = colors.red end

    writeAt(5, 13, "STATE  : " .. tostring(data.crusherState), stateColor)

    local energyText = "ENERGY : N/A"
    if type(data.energy) == "number" and type(data.maxEnergy) == "number" then
        energyText = ("ENERGY : %s / %s"):format(
            compact(data.energy, " FE"),
            compact(data.maxEnergy, " FE")
        )
    elseif type(data.energyFill) == "number" then
        energyText = ("ENERGY : %.1f%%"):format(data.energyFill * 100)
    end

    writeAt(5, 14, energyText, colors.lightGray)
    writeAt(5, 15, "USAGE  : " .. compact(data.energyUsage, " FE/t"), colors.lightGray)

    renderBarrel(18, "BIOFUEL BUFFER", data.output, colors.green)

    centered(
        math.max(24, height - 2),
        "V0.1 TELEMETRIE - AUCUN CONTROLE",
        colors.gray
    )

    if updateMessage and now < updateMessageUntil then
        centered(height, updateMessage, colors.yellow)
    else
        updateMessage = nil
    end
end

local function inside(bounds, x, y)
    return bounds
        and x >= bounds.x1
        and x <= bounds.x2
        and y >= bounds.y1
        and y <= bounds.y2
end

local function doUpdate()
    if not fs.exists(UPDATER_PATH) then
        updateMessage = "UPDATER ABSENT"
        updateMessageUntil = os.epoch("utc") / 1000 + 6
        render()
        return
    end

    local loaded, updater = pcall(dofile, UPDATER_PATH)

    if not loaded
        or type(updater) ~= "table"
        or type(updater.update) ~= "function" then

        updateMessage = "UPDATER INVALIDE"
        updateMessageUntil = os.epoch("utc") / 1000 + 6
        render()
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

        if event == "factory_biofuel_refresh" then
            render()

        elseif event == "monitor_touch" and p1 == monitorName then
            local x, y = p2, p3
            local now = os.epoch("utc") / 1000

            if inside(updateBounds, x, y) and not updateInProgress then
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

local function publishImmediateStatus()
    local statusBus = loadStatusBus()
    if statusBus and dataCache then
        local packet = buildModuleStatus(dataCache)
        pcall(statusBus.broadcastStatus, packet)
    end
end

local function statusLoop()
    local statusBus = loadStatusBus()

    while true do
        if not statusBus then
            statusBus = loadStatusBus()
        end

        if statusBus and dataCache then
            local packet = buildModuleStatus(dataCache)
            pcall(statusBus.broadcastStatus, packet)
        end

        sleep(config.status.publishSeconds)
    end
end

local function dataLoop()
    while true do
        local ok, fresh = pcall(collectData)

        if ok then
            dataCache = fresh
        else
            updateMessage = "ERREUR TELEMETRIE"
            updateMessageUntil = os.epoch("utc") / 1000 + 3
        end

        os.queueEvent("factory_biofuel_refresh")
        sleep(config.refreshSeconds)
    end
end

local function supervisorControlLoop()
    while true do
        local _, action, targetMode = os.pullEvent("factory_biofuel_control")

        if action == "toggle_mode" then
            if operatingMode == "AUTO" then
                operatingMode = "MANUAL"
                autoState.hold = false
                autoState.reason = "MANUAL"
            else
                operatingMode = "AUTO"
                autoState.hold = false
                autoState.reason = autoConfigured() and "AUTO INIT" or "AUTO WAIT TARGET"
            end
        elseif action == "crusher" and operatingMode == "MANUAL" then
            pcall(setCrusherMode, targetMode)
        end

        local refreshOK, fresh = pcall(collectData)
        if refreshOK then dataCache = fresh end
        publishImmediateStatus()
        os.queueEvent("factory_biofuel_refresh")
    end
end

local function autoLoop()
    while true do
        sleep(config.auto.checkSeconds)

        if operatingMode == "AUTO" and dataCache then
            local ok = pcall(applyAuto, dataCache)
            if ok then
                local refreshOK, fresh = pcall(collectData)
                if refreshOK then dataCache = fresh end
            else
                autoState.reason = "AUTO FAULT"
            end
            publishImmediateStatus()
            os.queueEvent("factory_biofuel_refresh")
        end
    end
end

if HEADLESS then
    parallel.waitForAny(dataLoop, statusLoop, supervisorControlLoop, autoLoop)
else
    parallel.waitForAny(uiLoop, dataLoop, statusLoop)
end
