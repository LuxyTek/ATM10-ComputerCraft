local M = {}

M.STATUS_PROTOCOL = "factory.status.v1"
M.CONTRACT_VERSION = 1

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

function M.validateStatus(packet)
    return type(packet) == "table"
        and packet.contract == M.CONTRACT_VERSION
        and type(packet.id) == "string"
        and packet.id ~= ""
        and type(packet.mode) == "string"
        and type(packet.state) == "string"
        and type(packet.health) == "string"
end

function M.broadcastStatus(packet)
    if type(packet) ~= "table" then
        return false, "status must be a table"
    end

    packet.contract = M.CONTRACT_VERSION

    if not M.validateStatus(packet) then
        return false, "invalid factory status packet"
    end

    if not rednet.isOpen() and M.open() == 0 then
        return false, "no rednet modem"
    end

    local ok = rednet.broadcast(packet, M.STATUS_PROTOCOL)
    return ok == true, ok == true and nil or "rednet broadcast failed"
end

return M
