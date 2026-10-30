local PROGRAM_VERSION = "0.1.1"
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

local monitor, monitorName = getMonitor()
monitor.setTextScale(config.textScale)

local width, height = monitor.getSize()

local updateBounds = nil
local updateConfirmUntil = 0
local updateMessage = nil
local updateMessageUntil = 0
local updateInProgress = false
local dataCache = nil

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
    elseif redstoneMode == nil then
        crusherState = "UNKNOWN"
    else
        crusherState = tostring(redstoneMode)
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
    elseif data.crusherState == "HIGH" then
        state = "STOP"
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

        mode = "MANUAL",
        state = state,
        health = health,
        reason = inputText .. " -> " .. outputText,

        metrics = {
            energy = data.energyFill,
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

parallel.waitForAny(uiLoop, dataLoop, statusLoop)
