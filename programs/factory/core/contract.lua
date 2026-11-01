local M = {}

M.VERSION = 2

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function validateIdList(items, fieldName)
    if items == nil then return true end
    if type(items) ~= "table" then
        return false, fieldName .. " must be a table"
    end

    local seen = {}
    for index, item in ipairs(items) do
        if type(item) ~= "table" then
            return false, ("%s[%d] must be a table"):format(fieldName, index)
        end
        if not nonEmptyString(item.id) then
            return false, ("%s[%d].id is required"):format(fieldName, index)
        end
        if seen[item.id] then
            return false, ("%s duplicate id: %s"):format(fieldName, item.id)
        end
        seen[item.id] = true
    end

    return true, nil, seen
end

function M.validateDefinition(definition)
    if type(definition) ~= "table" then
        return false, "definition must be a table"
    end

    if definition.contract ~= M.VERSION then
        return false, "unsupported definition contract"
    end
    if not nonEmptyString(definition.id) then
        return false, "definition.id is required"
    end
    if not nonEmptyString(definition.label) then
        return false, "definition.label is required"
    end
    if not nonEmptyString(definition.category) then
        return false, "definition.category is required"
    end

    local ok, err = validateIdList(definition.inputs, "inputs")
    if not ok then return false, err end

    ok, err = validateIdList(definition.outputs, "outputs")
    if not ok then return false, err end

    local machineSeen
    ok, err, machineSeen = validateIdList(definition.machines, "machines")
    if not ok then return false, err end

    local chainSeen
    ok, err, chainSeen = validateIdList(definition.chains, "chains")
    if not ok then return false, err end

    machineSeen = machineSeen or {}
    chainSeen = chainSeen or {}

    for index, machine in ipairs(definition.machines or {}) do
        if machine.chain ~= nil and not chainSeen[machine.chain] then
            return false, ("machines[%d] references unknown chain: %s")
                :format(index, tostring(machine.chain))
        end
    end

    for index, chain in ipairs(definition.chains or {}) do
        if chain.machines ~= nil then
            if type(chain.machines) ~= "table" then
                return false, ("chains[%d].machines must be a table"):format(index)
            end
            for _, machineId in ipairs(chain.machines) do
                if not machineSeen[machineId] then
                    return false, ("chain %s references unknown machine: %s")
                        :format(chain.id, tostring(machineId))
                end
            end
        end
    end

    if definition.actions ~= nil and type(definition.actions) ~= "table" then
        return false, "definition.actions must be a table"
    end

    return true
end

function M.validateStatus(status)
    if type(status) ~= "table" then
        return false, "status must be a table"
    end
    if status.contract ~= M.VERSION then
        return false, "unsupported status contract"
    end
    if not nonEmptyString(status.id) then
        return false, "status.id is required"
    end

    for _, field in ipairs({ "runtime", "mode", "state", "health" }) do
        if not nonEmptyString(status[field]) then
            return false, "status." .. field .. " is required"
        end
    end

    for _, field in ipairs({ "metrics", "resources", "chains", "machines", "alarms" }) do
        if status[field] ~= nil and type(status[field]) ~= "table" then
            return false, "status." .. field .. " must be a table"
        end
    end

    return true
end

function M.withDefaults(definition)
    local copy = {}
    for key, value in pairs(definition or {}) do copy[key] = value end

    copy.inputs = copy.inputs or {}
    copy.outputs = copy.outputs or {}
    copy.chains = copy.chains or {}
    copy.machines = copy.machines or {}
    copy.actions = copy.actions or {}

    return copy
end

return M
