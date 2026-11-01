local CORE="/programs/factory/core"
local UI="/programs/factory/ui"
local MODULES="/programs/factory/modules"

local bus=dofile(CORE.."/bus.lua")
local overview=dofile(UI.."/overview.lua")
local machines=dofile(UI.."/machines.lua")
local widgets=dofile(UI.."/widgets.lua")

local args={...}
local moduleId=tostring(args[1] or "")
local view=tostring(args[2] or "overview"):lower()
local display=tostring(args[3] or "monitor"):lower()
local timeout=tonumber(args[4]) or 30

if moduleId=="" then
    printError("Usage: module_v2_live <moduleId> <overview|machines|control> [monitor] [timeout]")
    return false
end

local moduleRoot=MODULES.."/"..moduleId
local definitionPath=moduleRoot.."/definition.lua"
local adapterPath=moduleRoot.."/legacy_adapter.lua"

if not fs.exists(definitionPath) then
    printError("Definition absente: "..definitionPath)
    return false
end
if not fs.exists(adapterPath) then
    printError("Legacy adapter absent: "..adapterPath)
    return false
end

local definition=dofile(definitionPath)
local adapter=dofile(adapterPath)

local function getMonitor()
    if display~="monitor"
        and peripheral.isPresent(display)
        and peripheral.hasType(display,"monitor") then
        local wrapped=peripheral.wrap(display)
        pcall(wrapped.setTextScale,0.5)
        return wrapped,display
    end

    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"monitor") then
            local wrapped=peripheral.wrap(name)
            if wrapped then
                pcall(wrapped.setTextScale,0.5)
                return wrapped,name
            end
        end
    end

    return nil,nil
end

local target,monitorName=getMonitor()
if not target then
    printError("Aucun monitor detecte.")
    return false
end

if bus.open()==0 then
    printError("Aucun modem Rednet disponible.")
    return false
end

local STATUS_PROTOCOL=bus.LEGACY_STATUS_PROTOCOL
local currentStatus=nil
local bounds={}
local currentView=view=="machines" and "machines" or "overview"

local function now()
    return os.epoch("utc")/1000
end

local function receiveStatus(seconds)
    local deadline=now()+(seconds or 5)

    while now()<deadline do
        local remaining=math.max(0.1,deadline-now())
        local sender,message=rednet.receive(
            STATUS_PROTOCOL,
            math.min(remaining,1)
        )

        if sender
            and type(message)=="table"
            and message.contract==1
            and message.id==moduleId then

            local status,err=adapter.fromLegacy(message)
            if status then return status,sender end
            return nil,nil,err
        end
    end

    return nil,nil,"timeout"
end

local initial,_,initialError=receiveStatus(timeout)
if not initial then
    printError(("Aucun statut %s: %s"):format(
        moduleId,tostring(initialError)
    ))
    return false
end
currentStatus=initial

if view~="control" then
    if view=="machines" then
        machines.render(target,definition,currentStatus,{})
    else
        overview.render(target,definition,currentStatus,{})
    end

    print(("%s V2 live: OK"):format(moduleId))
    print(("Mode %s | State %s | Health %s"):format(
        tostring(currentStatus.mode),
        tostring(currentStatus.state),
        tostring(currentStatus.health)
    ))
    return true
end

local width,height=target.getSize()
local tabOverview=nil
local tabMachines=nil
local backBounds=nil
local confirmBounds=nil
local cancelBounds=nil
local pending=nil
local message=nil
local messageColor=colors.lightGray
local messageUntil=0

local function writeAt(x,y,text,fg,bg)
    width,height=target.getSize()
    if y<1 or y>height or x<1 or x>width then return end
    target.setCursorPos(x,y)
    target.setTextColor(fg or colors.white)
    target.setBackgroundColor(bg or colors.black)
    target.write(tostring(text or ""):sub(1,width-x+1))
end

local function clearLine(y)
    width=select(1,target.getSize())
    writeAt(1,y,string.rep(" ",width),colors.white,colors.black)
end

local function drawTabs()
    width=select(1,target.getSize())

    local o="[ OVERVIEW ]"
    local m="[ MACHINES ]"
    local b="[ RETOUR ]"

    tabOverview={x1=3,x2=3+#o-1,y1=2,y2=2}
    tabMachines={x1=tabOverview.x2+3,x2=tabOverview.x2+3+#m-1,y1=2,y2=2}
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
    width,height=target.getSize()
    clearLine(height-1)
    clearLine(height)

    if pending and pending.expires>now() then
        local yes="[ CONFIRMER ]"
        local no="[ ANNULER ]"

        confirmBounds={
            x1=3,x2=3+#yes-1,
            y1=height-1,y2=height-1,
        }
        cancelBounds={
            x1=confirmBounds.x2+3,
            x2=confirmBounds.x2+3+#no-1,
            y1=height-1,y2=height-1,
        }

        writeAt(3,height-1,yes,colors.black,colors.orange)
        writeAt(cancelBounds.x1,height-1,no,colors.white,colors.red)
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
            "LIVE CONTROL - confirmation obligatoire",
            colors.gray
        )
    end

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

local function renderControl()
    if currentView=="machines" then
        bounds=machines.render(target,definition,currentStatus,{})
    else
        bounds=overview.render(
            target,
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

local function newRequestId()
    return ("%d-%d"):format(os.getComputerID(),os.epoch("utc"))
end

local function sendConfirmed(action,controlArgs)
    local requestId=newRequestId()
    local packet,err=bus.makeControl(
        moduleId,
        action,
        controlArgs or {},
        {
            requestId=requestId,
            confirmed=true,
            source="factory-v2-dev",
        }
    )
    if not packet then return false,err end

    rednet.broadcast(packet,bus.CONTROL_PROTOCOL)

    local deadline=now()+4
    while now()<deadline do
        local remaining=math.max(0.1,deadline-now())
        local sender,message,protocol=rednet.receive(nil,math.min(remaining,1))

        if sender
            and protocol==bus.CONTROL_ACK_PROTOCOL
            and type(message)=="table"
            and message.requestId==requestId
            and message.target==moduleId then
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
    renderControl()
end

local function findTouched(x,y)
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

local function executePending()
    if not pending or pending.expires<=now() then
        pending=nil
        renderControl()
        return
    end

    local action=pending.action
    local controlArgs=pending.args
    local label=pending.label
    pending=nil

    message="ENVOI "..label
    messageColor=colors.orange
    messageUntil=now()+4
    renderControl()

    local ok,detail=sendConfirmed(action,controlArgs)

    message=(ok and "OK: " or "ECHEC: ")..tostring(detail)
    messageColor=ok and colors.lime or colors.red
    messageUntil=now()+7

    if ok then
        local refreshed=receiveStatus(5)
        if refreshed then currentStatus=refreshed end
    end

    renderControl()
end

renderControl()
local refreshTimer=os.startTimer(2)

while true do
    local event,p1,p2,p3=os.pullEvent()

    if event=="monitor_touch" and p1==monitorName then
        local x,y=p2,p3

        if widgets.inside(backBounds,x,y) then
            target.setBackgroundColor(colors.black)
            target.clear()
            return true

        elseif widgets.inside(tabOverview,x,y) then
            currentView="overview"
            pending=nil
            renderControl()

        elseif widgets.inside(tabMachines,x,y) then
            currentView="machines"
            pending=nil
            renderControl()

        elseif pending and widgets.inside(confirmBounds,x,y) then
            executePending()

        elseif pending and widgets.inside(cancelBounds,x,y) then
            pending=nil
            message="ACTION ANNULEE"
            messageColor=colors.lightGray
            messageUntil=now()+3
            renderControl()

        else
            local entry=findTouched(x,y)
            if entry then queueConfirmation(entry) end
        end

    elseif event=="rednet_message" and p3==STATUS_PROTOCOL then
        local packet=p2
        if type(packet)=="table"
            and packet.contract==1
            and packet.id==moduleId then
            local status=adapter.fromLegacy(packet)
            if status then
                currentStatus=status
                renderControl()
            end
        end

    elseif event=="timer" and p1==refreshTimer then
        if pending and pending.expires<=now() then pending=nil end
        renderControl()
        refreshTimer=os.startTimer(2)
    end
end
