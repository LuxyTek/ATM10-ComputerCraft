local M={}

M.CONTROL_PROTOCOL="factory.control.v2"
M.ACK_PROTOCOL="factory.control.v2.ack"

local function openRednet()
    local opened=0

    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"modem") then
            if not rednet.isOpen(name) then
                local ok=pcall(rednet.open,name)
                if ok then opened=opened+1 end
            else
                opened=opened+1
            end
        end
    end

    return opened
end

local function sendAck(sender,target,packet,ok,detail,mode)
    if type(sender)~="number" then return end

    local ack={
        contract=2,
        target=target,
        requestId=tostring(packet and packet.requestId or ""),
        action=packet and packet.action or nil,
        ok=ok==true,
        detail=tostring(detail or ""),
        mode=mode,
    }

    pcall(rednet.send,sender,ack,M.ACK_PROTOCOL)
end

function M.run(options)
    options=options or {}

    local target=assert(options.target,"target required")
    local handle=assert(options.handle,"handle required")
    local enabled=options.enabled
    local getMode=options.getMode

    if enabled==false then
        while true do sleep(60) end
    end

    openRednet()

    while true do
        local _,sender,packet,protocol=os.pullEvent("rednet_message")

        if protocol==M.CONTROL_PROTOCOL
            and type(packet)=="table"
            and packet.contract==2
            and packet.target==target then

            local ok,detail

            if packet.confirmed~=true then
                ok,detail=false,"CONFIRMATION REQUIRED"
            elseif type(packet.action)~="string" or packet.action=="" then
                ok,detail=false,"INVALID ACTION"
            else
                local protected,handlerOK,handlerDetail=pcall(
                    handle,
                    packet
                )

                if protected then
                    ok,detail=handlerOK==true,handlerDetail
                else
                    ok,detail=false,"CONTROL ERROR: "..tostring(handlerOK)
                end
            end

            local mode=nil
            if type(getMode)=="function" then
                local modeOK,value=pcall(getMode)
                if modeOK then mode=value end
            end

            sendAck(sender,target,packet,ok,detail,mode)

            if ok and type(options.onAccepted)=="function" then
                pcall(options.onAccepted,packet)
            end
        end
    end
end

return M
