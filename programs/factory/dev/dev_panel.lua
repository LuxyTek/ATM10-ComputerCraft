local PANEL_VERSION="0.3.0"
local UPDATER_PATH="/programs/factory/dev/dev_updater.lua"
local STARTUP_LAUNCHER="/startup_factory_v2_dev.lua"
local STARTUP_PATH="/startup.lua"
local STARTUP_BACKUP="/startup.factory_v2_dev.bak"

local function getMonitor()
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name,"monitor") then
            return peripheral.wrap(name),name
        end
    end
    error("Aucun monitor detecte")
end

local monitor,monitorName=getMonitor()
pcall(monitor.setTextScale,0.5)

local width,height=monitor.getSize()
local buttons={}
local confirmUntil=0
local message=nil
local messageColor=colors.lightGray

local function writeAt(x,y,text,fg,bg)
    if y<1 or y>height then return end
    x=math.max(1,math.floor(x))
    if x>width then return end

    monitor.setCursorPos(x,y)
    monitor.setTextColor(fg or colors.white)
    monitor.setBackgroundColor(bg or colors.black)

    local available=width-x+1
    monitor.write(tostring(text or ""):sub(1,available))
end

local function centered(y,text,fg,bg)
    text=tostring(text or "")
    writeAt(math.max(1,math.floor((width-#text)/2)+1),y,text,fg,bg)
end

local function clear()
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()
end

local function inside(bounds,x,y)
    return bounds
        and x>=bounds.x1 and x<=bounds.x2
        and y>=bounds.y1 and y<=bounds.y2
end

local function button(id,x,y,label,fg,bg)
    writeAt(x,y,label,fg or colors.white,bg or colors.blue)
    buttons[id]={x1=x,x2=x+#label-1,y1=y,y2=y}
end

local function compactPath(path)
    local max=math.max(16,width-14)
    path=tostring(path or "")
    if #path<=max then return path end
    return "..."..path:sub(-(max-3))
end

local function render()
    width,height=monitor.getSize()
    buttons={}

    clear()
    centered(1,"FACTORY V2 DEV PANEL  v"..PANEL_VERSION,colors.cyan)
    centered(2,"refactor/factory-v2",colors.gray)

    local updateLabel=os.epoch("utc")/1000<confirmUntil
        and "[ CONFIRMER MAJ ]"
        or "[ MAJ V2 ]"
    local ux=math.max(2,width-#updateLabel-1)
    button(
        "update",
        ux,
        4,
        updateLabel,
        colors.white,
        os.epoch("utc")/1000<confirmUntil and colors.orange or colors.blue
    )

    writeAt(3,4,"DEVELOPPEMENT",colors.cyan)

    local y=7
    writeAt(3,y,"CORE",colors.cyan)
    button("core",18,y,"[ TEST ]",colors.black,colors.lime)

    y=y+3
    writeAt(3,y,"UI GENERIQUE",colors.cyan)
    button("flow",18,y,"[ FLOW ]")
    button("overview",29,y,"[ OVERVIEW ]")
    button("machines",44,y,"[ MACHINES ]")

    y=y+3
    writeAt(3,y,"H2/O2 FIXTURE",colors.cyan)
    button("h2overview",18,y,"[ OVERVIEW ]")
    button("h2machines",33,y,"[ MACHINES ]")

    y=y+3
    writeAt(3,y,"H2/O2 LIVE",colors.cyan)
    button("h2liveoverview",18,y,"[ OVERVIEW ]",colors.black,colors.lime)
    button("h2livemachines",33,y,"[ MACHINES ]",colors.black,colors.lime)
    button("h2control",48,y,"[ CONTROL ]",colors.black,colors.orange)

    y=y+3
    writeAt(3,y,"BIOFUEL LIVE",colors.cyan)
    button("bioliveoverview",18,y,"[ OVERVIEW ]",colors.black,colors.lime)
    button("biolivemachines",33,y,"[ MACHINES ]",colors.black,colors.lime)
    button("biocontrol",48,y,"[ CONTROL ]",colors.black,colors.orange)

    y=y+3
    writeAt(3,y,"HDPE LIVE",colors.cyan)
    button("hdpeliveoverview",18,y,"[ OVERVIEW ]",colors.black,colors.lime)
    button("hdpelivemachines",33,y,"[ MACHINES ]",colors.black,colors.lime)
    button("hdpecontrol",48,y,"[ CONTROL ]",colors.black,colors.orange)

    y=y+4
    writeAt(3,y,"SYSTEME",colors.cyan)
    if fs.exists(STARTUP_BACKUP) then
        button("restore",18,y,"[ RESTORE STARTUP ]",colors.white,colors.red)
    else
        writeAt(18,y,"Startup V2 Dev actif",colors.gray)
    end

    if message then
        writeAt(3,height-2,"STATUS:",colors.gray)
        writeAt(12,height-2,message,messageColor)
    end

    writeAt(3,height,"Toucher un bouton - aucun acces Computer requis",colors.gray)
end

local function waitForReturn()
    writeAt(3,height,"[ TOUCHER POUR RETOUR AU DEV PANEL ]",colors.black,colors.orange)
    while true do
        local event,name=os.pullEvent("monitor_touch")
        if name==monitorName then break end
    end
    render()
end

local function runScreenTest(label,path,...)
    clear()
    centered(2,label,colors.cyan)
    centered(4,"Lancement...",colors.lightGray)

    local ok=shell.run(path,...)

    if ok then
        writeAt(3,height,"[ TOUCHER POUR RETOUR AU DEV PANEL ]",colors.black,colors.orange)
    else
        clear()
        centered(math.max(2,math.floor(height/2)-1),label,colors.cyan)
        centered(math.max(3,math.floor(height/2)+1),"ECHEC",colors.red)
    end

    waitForReturn()
end

local function runInteractive(path,...)
    clear()
    local ok=shell.run(path,...)
    if not ok then
        clear()
        centered(math.max(2,math.floor(height/2)-1),"TEST INTERACTIF ECHEC",colors.red)
        sleep(1)
    end
    render()
end

local function runCoreTest()
    clear()
    centered(math.max(2,math.floor(height/2)-2),"FACTORY CORE V2",colors.cyan)
    centered(math.max(3,math.floor(height/2)),"TEST EN COURS...",colors.lightGray)

    local ok=shell.run("/programs/factory/tools/core_v2_smoke_test.lua")

    clear()
    centered(math.max(2,math.floor(height/2)-2),"FACTORY CORE V2",colors.cyan)
    centered(
        math.max(3,math.floor(height/2)),
        ok and "TEST OK" or "TEST ECHEC",
        ok and colors.lime or colors.red
    )

    waitForReturn()
end

local function updateProgress(stage,current,total,label)
    clear()
    centered(2,"FACTORY V2 UPDATE",colors.cyan)

    writeAt(3,5,"ETAPE :",colors.gray)
    writeAt(13,5,tostring(stage):upper(),colors.white)

    if total and total>0 then
        writeAt(3,7,("FICHIER : %d / %d"):format(current or 0,total),colors.lightGray)

        local barX=3
        local barY=9
        local barWidth=math.max(10,width-6)
        local fill=math.max(0,math.min(1,(current or 0)/total))
        local filled=math.floor(barWidth*fill+0.5)

        writeAt(barX,barY,string.rep(" ",barWidth),colors.white,colors.gray)
        if filled>0 then
            writeAt(barX,barY,string.rep(" ",filled),colors.black,colors.lime)
        end
    end

    if label then
        writeAt(3,12,compactPath(label),colors.gray)
    end
end

local function doUpdate()
    if not fs.exists(UPDATER_PATH) then
        message="UPDATER ABSENT"
        messageColor=colors.red
        render()
        return
    end

    local okLoad,updater=pcall(dofile,UPDATER_PATH)
    if not okLoad or type(updater)~="table" or type(updater.update)~="function" then
        message="UPDATER INVALIDE"
        messageColor=colors.red
        render()
        return
    end

    local ok,result=updater.update(updateProgress)

    clear()
    if ok then
        centered(math.max(2,math.floor(height/2)-1),"MISE A JOUR V2 OK",colors.lime)
        centered(math.max(3,math.floor(height/2)+1),"Version "..tostring(result),colors.lightGray)
        sleep(1)
        os.reboot()
    else
        centered(math.max(2,math.floor(height/2)-2),"ECHEC MISE A JOUR V2",colors.red)
        centered(math.max(3,math.floor(height/2)),tostring(result),colors.orange)
        waitForReturn()
    end
end

local function restoreStartup()
    if not fs.exists(STARTUP_BACKUP) then
        message="AUCUNE BACKUP STARTUP"
        messageColor=colors.orange
        render()
        return
    end

    if fs.exists(STARTUP_PATH) then fs.delete(STARTUP_PATH) end
    fs.move(STARTUP_BACKUP,STARTUP_PATH)

    clear()
    centered(math.max(2,math.floor(height/2)-1),"STARTUP RESTAURE",colors.lime)
    centered(math.max(3,math.floor(height/2)+1),"Redemarrage...",colors.lightGray)
    sleep(1)
    os.reboot()
end

render()

while true do
    local _,name,x,y=os.pullEvent("monitor_touch")

    if name==monitorName then
        if inside(buttons.update,x,y) then
            local now=os.epoch("utc")/1000
            if now<confirmUntil then
                confirmUntil=0
                doUpdate()
            else
                confirmUntil=now+8
                message="CONFIRMER LA MAJ"
                messageColor=colors.orange
                render()
            end

        elseif inside(buttons.core,x,y) then
            runCoreTest()

        elseif inside(buttons.flow,x,y) then
            runScreenTest(
                "UI V2 - FLOW",
                "/programs/factory/tools/ui_v2_smoke_test.lua",
                "flow",
                "monitor"
            )

        elseif inside(buttons.overview,x,y) then
            runScreenTest(
                "UI V2 - OVERVIEW",
                "/programs/factory/tools/ui_v2_smoke_test.lua",
                "overview",
                "monitor"
            )

        elseif inside(buttons.machines,x,y) then
            runScreenTest(
                "UI V2 - MACHINES",
                "/programs/factory/tools/ui_v2_smoke_test.lua",
                "machines",
                "monitor"
            )

        elseif inside(buttons.h2overview,x,y) then
            runScreenTest(
                "H2/O2 V2 - FIXTURE OVERVIEW",
                "/programs/factory/tools/h2o2_v2_smoke_test.lua",
                "overview",
                "monitor"
            )

        elseif inside(buttons.h2machines,x,y) then
            runScreenTest(
                "H2/O2 V2 - FIXTURE MACHINES",
                "/programs/factory/tools/h2o2_v2_smoke_test.lua",
                "machines",
                "monitor"
            )

        elseif inside(buttons.h2liveoverview,x,y) then
            runScreenTest(
                "H2/O2 V2 - LIVE OVERVIEW",
                "/programs/factory/tools/h2o2_v2_live_test.lua",
                "overview",
                "monitor",
                "30"
            )

        elseif inside(buttons.h2livemachines,x,y) then
            runScreenTest(
                "H2/O2 V2 - LIVE MACHINES",
                "/programs/factory/tools/h2o2_v2_live_test.lua",
                "machines",
                "monitor",
                "30"
            )

        elseif inside(buttons.h2control,x,y) then
            runInteractive(
                "/programs/factory/tools/h2o2_v2_control.lua",
                "monitor"
            )

        elseif inside(buttons.bioliveoverview,x,y) then
            runScreenTest(
                "BIOFUEL V2 - LIVE OVERVIEW",
                "/programs/factory/tools/module_v2_live.lua",
                "biofuel",
                "overview",
                "monitor",
                "30"
            )

        elseif inside(buttons.biolivemachines,x,y) then
            runScreenTest(
                "BIOFUEL V2 - LIVE MACHINES",
                "/programs/factory/tools/module_v2_live.lua",
                "biofuel",
                "machines",
                "monitor",
                "30"
            )

        elseif inside(buttons.biocontrol,x,y) then
            runInteractive(
                "/programs/factory/tools/module_v2_live.lua",
                "biofuel",
                "control",
                "monitor",
                "30"
            )

        elseif inside(buttons.hdpeliveoverview,x,y) then
            runScreenTest(
                "HDPE V2 - LIVE OVERVIEW",
                "/programs/factory/tools/module_v2_live.lua",
                "hdpe",
                "overview",
                "monitor",
                "30"
            )

        elseif inside(buttons.hdpelivemachines,x,y) then
            runScreenTest(
                "HDPE V2 - LIVE MACHINES",
                "/programs/factory/tools/module_v2_live.lua",
                "hdpe",
                "machines",
                "monitor",
                "30"
            )

        elseif inside(buttons.hdpecontrol,x,y) then
            runInteractive(
                "/programs/factory/tools/module_v2_live.lua",
                "hdpe",
                "control",
                "monitor",
                "30"
            )

        elseif inside(buttons.restore,x,y) then
            restoreStartup()
        end
    end
end
