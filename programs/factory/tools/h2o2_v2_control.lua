local MODULE="/programs/factory/modules/h2o2"
local CORE="/programs/factory/core"
local UI="/programs/factory/ui"

local definition=dofile(MODULE.."/definition.lua")
local adapter=dofile(MODULE.."/legacy_adapter.lua")
local bus=dofile(CORE.."/bus.lua")
local overview=dofile(UI.."/overview.lua")
local machines=dofile(UI.."/machines.lua")
local widgets=dofile(UI.."/widgets.lua")

local STATUS_PROTOCOL="factory.status.v1"
local TARGET="h2o2"

local function openRednet()
    return bus.open()
end

local function getMonitor()
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"monitor") then
            local monitor=peripheral.wrap(name)
            if monitor then
                pcall(monitor.setTextScale,0.5)
                return monitor,name
            end
        end
    end

    return nil,nil
end

local monitor,monitorName=getMonitor()
if not monitor then
    printError("Aucun monitor detecte.")
    return false
end

if openRednet()==0 then
    printError("Aucun modem Rednet disponible.")
    return false
end

local currentView="overview"
local currentStatus=nil
local bounds={}
local tabOverview=nil
local tabMachines=nil
local backBounds=nil
local confirmBounds=nil
local cancelBounds=nil
local pending=nil
local message=nil
local messageColor=colors.lightGray
local messageUntil=0

local function now()
    return os.epoch("utc")/1000
end

local function writeAt(x,y,text,fg,bg)
    local width,height=monitor.getSize()
    if y<1 or y>height then return end
    if x<1 or x>width then return end

    monitor.setCursorPos(x,y)
    monitor.setTextColor(fg or colors.white)
    monitor.setBackgroundColor(bg or colors.black)
    monitor.write(tostring(text or ""):sub(1,width-x+1))
end

local function clearLine(y)
    local width=select(1,monitor.getSize())
    writeAt(1,y,string.rep(" ",width),colors.white,colors.black)
end

local function drawTabs()
    local width=select(1,monitor.getSize())

    local o="[ OVERVIEW ]"
    local m="[ MACHINES ]"
    local b="[ RETOUR ]"

    tabOverview={x1=3,x2=3+#o-1,y1=2,y2=2}
    tabMachines={x1=3+#o+2,x2=3+#o+2+#m-1,y1=2,y2=2}
    backBounds={x1=width-#b-1,x2=width-2,y1=2,y2=2}

    writeAt(
        tabOverview.x1,2,o,colors.white,
        currentView=="overview" and colors.blue or colors.gray
    )
    writeAt(
        tabMachines.x1,2,m,colors.white,
        currentView=="machines" and colors.blue or colors.gray
    )
    writeAt(backBounds.x1,2,b,colors.white,colors.gray)
end

local function drawFooter()
    local width,height=monitor.getSize()

    clearLine(height-1)
    clearLine(height)

    if pending and pending.expires>now() then
        local label="[ CONFIRMER ]"
        local cancel="[ ANNULER ]"
        confirmBounds={
            x1=3,x2=3+#label-1,
            y1=height-1,y2=height-1,
        }
        cancelBounds={
            x1=confirmBounds.x2+3,
            x2=confirmBounds.x2+3+#cancel-1,
            y1=height-1,y2=height-1,
        }

        writeAt(3,height-1,label,colors.black,colors.orange)
        writeAt(cancelBounds.x1,height-1,cancel,colors.white,colors.red)
        writeAt(
            3,height,
            "ACTION: "..tostring(pending.label or pending.action),
            colors.orange
        )
        return
    end

    pending=nil
    confirmBounds=nil
    cancelBounds=nil

    if message and now()<messageUntil then
        writeAt(3,height-1,"STATUS: "..message,messageColor)
    else
        message=nil
        writeAt(
            3,height-1,
            "LIVE CONTROL - 2e confirmation obligatoire",
            colors.gray
        )
    end

    if currentStatus then
        writeAt(
            3,height,
            ("MODE %s | STATE %s | HEALTH %s"):format(
                tostring(currentStatus.mode),
                tostring(currentStatus.state),
                tostring(currentStatus.health)
            ),
            colors.lightGray
        )
    end
end

local function render()
    if not currentStatus then
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        local width=select(1,monitor.getSize())
        writeAt(
            math.max(1,math.floor((width-28)/2)),
            4,
            "ATTENTE STATUT H2/O2...",
            colors.cyan
        )
        return
    end

    if currentView=="machines" then
        bounds=machines.render(monitor,definition,currentStatus,{})
    else
        bounds=overview.render(
            monitor,
            definition,
            currentStatus,
            {
                allowModuleControls=true,
                allowChainControls=true,
            }
        )
    end

    drawTabs()
    drawFooter()
end

local function receiveLegacyStatus(timeout)
    local deadline=now()+(timeout or 5)

    while now()<deadline do
        local remaining=math.max(0.1,deadline-now())
        local sender,message=rednet.receive(
            STATUS_PROTOCOL,
            math.min(remaining,1)
        )

        if sender
            and type(message)=="table"
            and message.contract==1
            and message.id=="h2o2" then
            local status,err=adapter.fromLegacy(message)
            if status then return status,sender end
            return nil,nil,err
        end
    end

    return nil,nil,"timeout"
end

local function newRequestId()
    return ("%d-%d"):format(
        os.getComputerID(),
        os.epoch("utc")
    )
end

local function sendConfirmedControl(action,args,label)
    local requestId=newRequestId()
    local packet,packetError=bus.makeControl(
        TARGET,
        action,
        args or {},
        {
            requestId=requestId,
            confirmed=true,
            source="factory-v2-dev",
        }
    )

    if not packet then
        return false,packetError
    end

    rednet.broadcast(packet,bus.CONTROL_PROTOCOL)

    local deadline=now()+4

    while now()<deadline do
        local remaining=math.max(0.1,deadline-now())
        local sender,message,protocol=rednet.receive(nil,math.min(remaining,1))

        if protocol==bus.CONTROL_ACK_PROTOCOL
            and type(message)=="table"
            and message.requestId==requestId
            and message.target==TARGET then
            return message.ok==true,message.detail or "ACK"
        end
    end

    return false,"AUCUN ACK DU RUNTIME"
end

local function queueConfirmation(entry)
    if not entry or not entry.action then return end

    pending={
        action=entry.action,
        args=entry.args or {},
        label=entry.label or entry.action,
        expires=now()+8,
    }
    render()
end

local function refreshStatus(timeout)
    local status,_,err=receiveLegacyStatus(timeout or 5)

    if status then
        currentStatus=status
        return true
    end

    message="STATUS: "..tostring(err or "N/A")
    messageColor=colors.orange
    messageUntil=now()+5
    return false
end

local function executePending()
    if not pending or pending.expires<=now() then
        pending=nil
        render()
        return
    end

    local action=pending.action
    local args=pending.args
    local label=pending.label
    pending=nil

    message="ENVOI "..label
    messageColor=colors.orange
    messageUntil=now()+5
    render()

    local ok,detail=sendConfirmedControl(action,args,label)

    message=(ok and "OK: " or "ECHEC: ")..tostring(detail)
    messageColor=ok and colors.lime or colors.red
    messageUntil=now()+7

    if ok then
        refreshStatus(5)
    end

    render()
end

local function findTouchedControl(x,y)
    if currentView=="machines" then
        for _,entry in pairs(bounds.machines or {}) do
            if widgets.inside(entry,x,y) then return entry end
        end
        return nil
    end

    for _,entry in pairs(bounds.module or {}) do
        if widgets.inside(entry,x,y) then return entry end
    end

    for _,entry in pairs(bounds.chains or {}) do
        if widgets.inside(entry,x,y) then return entry end
    end

    return nil
end

local initial,_,initialError=receiveLegacyStatus(30)
if not initial then
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    writeAt(3,4,"AUCUN STATUT H2/O2: "..tostring(initialError),colors.red)
    sleep(2)
    return false
end

currentStatus=initial
render()

local refreshTimer=os.startTimer(2)

while true do
    local event,p1,p2,p3=os.pullEvent()

    if event=="monitor_touch" and p1==monitorName then
        local x,y=p2,p3

        if widgets.inside(backBounds,x,y) then
            monitor.setBackgroundColor(colors.black)
            monitor.clear()
            return true

        elseif widgets.inside(tabOverview,x,y) then
            currentView="overview"
            pending=nil
            render()

        elseif widgets.inside(tabMachines,x,y) then
            currentView="machines"
            pending=nil
            render()

        elseif pending and widgets.inside(confirmBounds,x,y) then
            executePending()

        elseif pending and widgets.inside(cancelBounds,x,y) then
            pending=nil
            message="ACTION ANNULEE"
            messageColor=colors.lightGray
            messageUntil=now()+3
            render()

        else
            local entry=findTouchedControl(x,y)
            if entry then queueConfirmation(entry) end
        end

    elseif event=="rednet_message" and p3==STATUS_PROTOCOL then
        local messagePacket=p2
        if type(messagePacket)=="table"
            and messagePacket.contract==1
            and messagePacket.id=="h2o2" then
            local status=adapter.fromLegacy(messagePacket)
            if status then
                currentStatus=status
                render()
            end
        end

    elseif event=="timer" and p1==refreshTimer then
        if pending and pending.expires<=now() then pending=nil end
        render()
        refreshTimer=os.startTimer(2)
    end
end
