local M = {}

local function inferRuntime(packet)
    if type(packet.runtimeState) == "string" and packet.runtimeState ~= "" then
        return packet.runtimeState
    end
    if packet.health == "FAULT" then return "FAULT" end
    if packet.state == "RUN" then return "ACTIVE" end
    if packet.state == "HOLD" or packet.state == "IDLE" then return "IDLE" end
    if packet.state == "STOP" then return "IDLE" end
    return "UNKNOWN"
end

local function normalizeLegacyMachineId(machine, index)
    local source = tostring(machine.name or machine.kind or ("machine_" .. index))
    local id = source:lower():gsub("[^%w_%-]+", "_")
    if id == "" then id = "machine_" .. index end
    return id
end

function M.fromV1(packet)
    if type(packet) ~= "table" or packet.contract ~= 1 then
        return nil, "not a contract v1 packet"
    end
    if type(packet.id) ~= "string" or packet.id == "" then
        return nil, "legacy packet id is required"
    end

    local machines = {}
    local legacyMachines =
        type(packet.ui) == "table"
        and type(packet.ui.machines) == "table"
        and packet.ui.machines
        or {}

    for index, machine in ipairs(legacyMachines) do
        local id = normalizeLegacyMachineId(machine, index)
        if machines[id] ~= nil then id = id .. "_" .. tostring(index) end

        machines[id] = {
            peripheral = machine.name,
            kind = machine.kind,
            state = machine.state or "UNKNOWN",
            energy = machine.energy,
            maxEnergy = machine.maxEnergy,
            energyUsage = machine.energyUsage,
            controllable = false,
            legacy = true,
        }
    end

    local resources = {}
    for key, value in pairs(type(packet.metrics) == "table" and packet.metrics or {}) do
        if type(value) == "number" then
            resources[key] = { value=value }
            if value >= 0 and value <= 1 then resources[key].fill = value end
        end
    end

    return {
        contract = 2,
        id = packet.id,
        label = packet.label,
        category = packet.type or "process",
        version = packet.version,

        runtime = inferRuntime(packet),
        mode = packet.mode or "UNKNOWN",
        state = packet.state or "UNKNOWN",
        health = packet.health or "UNKNOWN",
        reason = packet.reason or "LEGACY V1",

        metrics = packet.metrics or {},
        resources = resources,
        chains = {},
        machines = machines,
        alarms = packet.alarms or {},

        legacy = {
            contract = 1,
            ui = packet.ui,
            details = packet.details,
            activeLines = packet.activeLines,
            totalLines = packet.totalLines,
        },
    }
end

function M.normalize(packet)
    if type(packet) ~= "table" then
        return nil, "status must be a table"
    end

    if packet.contract == 2 then return packet end
    if packet.contract == 1 then return M.fromV1(packet) end

    return nil, "unsupported contract: " .. tostring(packet.contract)
end

return M
