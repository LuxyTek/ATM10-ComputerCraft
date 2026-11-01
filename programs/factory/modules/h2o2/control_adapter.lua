local M = {}

local STOP_MODE="HIGH"
local RUN_MODE="DISABLED"

local function legacyLineId(chainId)
    local number=tostring(chainId or ""):match("^line_(%d+)$")
    if not number then return nil end
    return "LINE "..number
end

local function machinePeripheral(status,machineId)
    local machines=type(status)=="table" and status.machines or nil
    local machine=type(machines)=="table" and machines[machineId] or nil
    return type(machine)=="table" and machine.peripheral or nil
end

function M.dispatch(packet,currentStatus)
    if type(packet)~="table"
        or packet.contract~=2
        or packet.target~="h2o2"
        or type(packet.action)~="string" then
        return false,"invalid h2o2 control packet"
    end

    local args=type(packet.args)=="table" and packet.args or {}
    local action=packet.action

    if action=="module.set_mode" then
        local targetMode=tostring(args.mode or "")
        if targetMode~="AUTO" and targetMode~="MANUAL" then
            return false,"mode must be AUTO or MANUAL"
        end

        local current=tostring(type(currentStatus)=="table" and currentStatus.mode or "")
        if current==targetMode then return true,"already "..targetMode end

        os.queueEvent("factory_h2o2_mode_toggle")
        return true,"mode toggle queued"
    end

    if tostring(type(currentStatus)=="table" and currentStatus.mode or "")
        ~= "MANUAL" then
        return false,"manual mode required"
    end

    if action=="module.start_all" then
        os.queueEvent(
            "factory_control_request",
            "all",
            "ALL",
            RUN_MODE,
            "START ALL"
        )
        return true,"start all queued"
    end

    if action=="module.stop_all" then
        os.queueEvent(
            "factory_control_request",
            "all",
            "ALL",
            STOP_MODE,
            "STOP ALL"
        )
        return true,"stop all queued"
    end

    if action=="chain.start" or action=="chain.stop" then
        local lineId=legacyLineId(args.chainId)
        if not lineId then return false,"unknown chain id" end

        local mode=action=="chain.start" and RUN_MODE or STOP_MODE
        local label=(action=="chain.start" and "START " or "STOP ")..lineId

        os.queueEvent(
            "factory_control_request",
            "line",
            lineId,
            mode,
            label
        )
        return true,"line control queued"
    end

    if action=="machine.start" or action=="machine.stop" then
        local peripheralName=machinePeripheral(currentStatus,args.machineId)
        if not peripheralName then return false,"machine peripheral unavailable" end

        local mode=action=="machine.start" and RUN_MODE or STOP_MODE
        local label=(action=="machine.start" and "START " or "STOP ")
            ..tostring(args.machineId)

        os.queueEvent(
            "factory_control_request",
            "machine",
            peripheralName,
            mode,
            label
        )
        return true,"machine control queued"
    end

    return false,"unsupported h2o2 action: "..tostring(action)
end

return M
