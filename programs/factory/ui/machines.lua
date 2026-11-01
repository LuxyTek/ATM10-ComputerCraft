local widgets = dofile("/programs/factory/ui/widgets.lua")

local M = {}

local function supports(definition,action)
    local actions=definition.actions or {}
    if actions[action]==true then return true end

    for _,value in ipairs(actions) do
        if value==action then return true end
    end

    return false
end

local function findMachineDefinition(definition,id)
    for _,machine in ipairs(definition.machines or {}) do
        if machine.id==id then return machine end
    end
    return nil
end

local function renderMachine(w,y,machineDef,machineStatus,mode,canControl,bounds)
    machineStatus=machineStatus or {}

    local label=tostring(machineDef.label or machineDef.id or "MACHINE")
    local state=tostring(machineStatus.state or "UNKNOWN")

    w:writeAt(5,y,label,colors.lightBlue)
    w:writeAt(21,y,tostring(machineStatus.peripheral or "NON MAPPE"),colors.white)
    w:writeAt(math.max(44,w.width-20),y,state,widgets.stateColor(state))

    if canControl then
        local running=state=="RUN"
        local buttonLabel=running and "[ STOP ]" or "[ START ]"
        local action=running and "machine.stop" or "machine.start"
        local x=w.width-#buttonLabel-1

        bounds[machineDef.id]=w:button(x,y,buttonLabel,true,false)
        bounds[machineDef.id].action=action
        bounds[machineDef.id].machineId=machineDef.id
    elseif mode=="AUTO" then
        w:writeAt(w.width-9,y,"[ AUTO ]",colors.lightGray,colors.gray)
    end

    local energy="ENERGY N/A"
    if type(machineStatus.energy)=="number"
        and type(machineStatus.maxEnergy)=="number" then
        energy=("ENERGY %s / %s"):format(
            widgets.compact(machineStatus.energy," FE"),
            widgets.compact(machineStatus.maxEnergy," FE")
        )
    end

    local usage="USAGE "..widgets.compact(machineStatus.energyUsage," FE/t")
    w:writeAt(21,y+1,energy.." | "..usage,colors.gray)
end

function M.render(target,definition,status,options)
    options=options or {}
    status=status or {}

    local w=widgets.new(target)
    if options.clear~=false then w:clear() end

    w:centered(1,("FACTORY %s - MACHINES"):format(
        tostring(definition.label or definition.id or "?")
    ),colors.cyan)

    local mode=tostring(status.mode or "UNKNOWN")
    local statusMachines=type(status.machines)=="table" and status.machines or {}
    local bounds={machines={}}
    local y=3

    local canMachineStart=supports(definition,"machine.start")
    local canMachineStop=supports(definition,"machine.stop")
    local manual=mode=="MANUAL"

    local rendered={}

    for _,chain in ipairs(definition.chains or {}) do
        if y>=w.height-2 then break end

        w:writeAt(3,y,"[ "..tostring(chain.label or chain.id).." ]",colors.cyan)
        y=y+1

        local found=false
        for _,machineId in ipairs(chain.machines or {}) do
            local machineDef=findMachineDefinition(definition,machineId)
            if machineDef then
                found=true
                rendered[machineId]=true

                local machineStatus=statusMachines[machineId] or {}
                local state=tostring(machineStatus.state or "UNKNOWN")
                local wantsStop=state=="RUN"
                local canControl=manual
                    and machineStatus.controllable~=false
                    and ((wantsStop and canMachineStop)
                        or (not wantsStop and canMachineStart))

                renderMachine(
                    w,y,machineDef,machineStatus,mode,canControl,bounds.machines
                )
                y=y+3
                if y>=w.height-2 then break end
            end
        end

        if not found then
            w:writeAt(5,y,"AUCUNE MACHINE MAPPEE",colors.gray)
            y=y+1
        end

        y=y+1
    end

    local unassigned={}
    for _,machineDef in ipairs(definition.machines or {}) do
        if not rendered[machineDef.id] then
            table.insert(unassigned,machineDef)
        end
    end

    if #unassigned>0 and y<w.height-2 then
        w:writeAt(3,y,"[ NON ASSIGNE ]",colors.cyan)
        y=y+1

        for _,machineDef in ipairs(unassigned) do
            if y>=w.height-2 then break end

            local machineStatus=statusMachines[machineDef.id] or {}
            local state=tostring(machineStatus.state or "UNKNOWN")
            local wantsStop=state=="RUN"
            local canControl=manual
                and machineStatus.controllable~=false
                and ((wantsStop and canMachineStop)
                    or (not wantsStop and canMachineStart))

            renderMachine(
                w,y,machineDef,machineStatus,mode,canControl,bounds.machines
            )
            y=y+3
        end
    end

    if mode=="AUTO" then
        w:writeAt(3,w.height-1,"AUTO ACTIF - CONTROLES MACHINES VERROUILLES",colors.lightGray)
    elseif manual then
        w:writeAt(3,w.height-1,"MANUAL - CONTROLE MACHINE INDIVIDUEL",colors.yellow)
    end

    return bounds
end

return M
