local CONTRACT_PATH = "/programs/factory/core/contract.lua"
local ADAPTER_PATH = "/programs/factory/core/status_adapter.lua"

local contract = dofile(CONTRACT_PATH)
local adapter = dofile(ADAPTER_PATH)

local M = {}

M.STATUS_PROTOCOL = "factory.status.v2"
M.CONTROL_PROTOCOL = "factory.control.v2"
M.LEGACY_STATUS_PROTOCOL = "factory.status.v1"

M.LOCAL_STATUS_EVENT = "factory_v2_status"
M.LOCAL_CONTROL_EVENT = "factory_v2_control"

function M.open()
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

function M.normalizeStatus(packet)
    local normalized, adaptError = adapter.normalize(packet)
    if not normalized then return nil, adaptError end

    local valid, validationError = contract.validateStatus(normalized)
    if not valid then return nil, validationError end

    return normalized
end

function M.broadcastStatus(packet)
    local normalized, normalizeError = M.normalizeStatus(packet)
    if not normalized then return false, normalizeError end
    if normalized.contract ~= 2 then return false, "status must normalize to contract v2" end

    os.queueEvent(M.LOCAL_STATUS_EVENT, normalized)

    if not rednet.isOpen() and M.open() == 0 then
        return true, "local only"
    end

    local ok = rednet.broadcast(normalized, M.STATUS_PROTOCOL)
    return ok == true, ok == true and nil or "rednet broadcast failed"
end

function M.makeControl(targetId, action, args)
    if type(targetId) ~= "string" or targetId == "" then
        return nil, "targetId is required"
    end
    if type(action) ~= "string" or action == "" then
        return nil, "action is required"
    end

    return {
        contract = 2,
        target = targetId,
        action = action,
        args = type(args) == "table" and args or {},
    }
end

function M.broadcastControl(targetId, action, args)
    local packet, packetError = M.makeControl(targetId, action, args)
    if not packet then return false, packetError end

    os.queueEvent(M.LOCAL_CONTROL_EVENT, packet)

    if not rednet.isOpen() and M.open() == 0 then
        return true, "local only"
    end

    local ok = rednet.broadcast(packet, M.CONTROL_PROTOCOL)
    return ok == true, ok == true and nil or "rednet broadcast failed"
end

function M.parseEvent(event, p1, p2, p3)
    if event == M.LOCAL_STATUS_EVENT then
        local status, err = M.normalizeStatus(p1)
        if status then return "status", status, os.getComputerID() end
        return nil, nil, nil, err
    end

    if event == M.LOCAL_CONTROL_EVENT then
        return "control", p1, os.getComputerID()
    end

    if event ~= "rednet_message" then return nil end

    local sender = p1
    local packet = p2
    local protocol = p3

    if protocol == M.STATUS_PROTOCOL or protocol == M.LEGACY_STATUS_PROTOCOL then
        local status, err = M.normalizeStatus(packet)
        if status then return "status", status, sender end
        return nil, nil, sender, err
    end

    if protocol == M.CONTROL_PROTOCOL then
        if type(packet) == "table"
            and packet.contract == 2
            and type(packet.target) == "string"
            and type(packet.action) == "string" then
            return "control", packet, sender
        end
        return nil, nil, sender, "invalid control packet"
    end

    return nil
end

return M
