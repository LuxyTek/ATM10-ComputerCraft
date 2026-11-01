local MODULE="/programs/factory/modules/h2o2"
local CORE="/programs/factory/core"
local UI="/programs/factory/ui"

local definition=dofile(MODULE.."/definition.lua")
local adapter=dofile(MODULE.."/legacy_adapter.lua")
local overview=dofile(UI.."/overview.lua")
local machines=dofile(UI.."/machines.lua")

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

local args={...}
local view=tostring(args[1] or "overview"):lower()
local display=tostring(args[2] or "monitor"):lower()
local timeout=tonumber(args[3]) or 30

local target=term.current()
if display=="monitor" then
    local found=peripheral.find("monitor")
    if found then
        target=found
        pcall(target.setTextScale,0.5)
    else
        printError("Aucun monitor detecte, utilisation du terminal.")
    end
elseif peripheral.isPresent(args[2]) and peripheral.hasType(args[2],"monitor") then
    target=peripheral.wrap(args[2])
    pcall(target.setTextScale,0.5)
end

if openRednet()==0 then
    printError("Aucun modem Rednet disponible.")
    return false
end

print(("Attente statut H2/O2 V1 (%ds max)..."):format(timeout))

local deadline=os.epoch("utc")/1000+timeout
local legacy=nil

while os.epoch("utc")/1000<deadline do
    local remaining=math.max(0.1,deadline-os.epoch("utc")/1000)
    local _,message=rednet.receive("factory.status.v1",math.min(remaining,3))

    if type(message)=="table"
        and message.contract==1
        and message.id=="h2o2" then
        legacy=message
        break
    end
end

if not legacy then
    printError("Aucun statut H2/O2 recu.")
    printError("Executer ce test sur un Computer relie au meme reseau Rednet.")
    return false
end

local status,err=adapter.fromLegacy(legacy)
if not status then
    printError("Adaptation V2 echouee: "..tostring(err))
    return false
end

if view=="machines" then
    machines.render(target,definition,status,{})
else
    overview.render(target,definition,status,{})
end

print("H2/O2 V2 live test: OK")
print(("Mode %s | State %s | Health %s"):format(
    tostring(status.mode),
    tostring(status.state),
    tostring(status.health)
))
print(("Chains %d | Machines %d"):format(
    (function()
        local n=0
        for _ in pairs(status.chains or {}) do n=n+1 end
        return n
    end)(),
    (function()
        local n=0
        for _ in pairs(status.machines or {}) do n=n+1 end
        return n
    end)()
))

return true
