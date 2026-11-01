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

local function resourceValue(status,id)
    local resource=type(status.resources)=="table" and status.resources[id] or nil
    if type(resource)=="table" then
        if type(resource.fill)=="number" then return resource.fill,"fill" end
        if resource.value~=nil then return resource.value,"value" end
        if resource.count~=nil then return resource.count,"count" end
    end

    local metric=type(status.metrics)=="table" and status.metrics[id] or nil
    if metric~=nil then
        if type(metric)=="number" and metric>=0 and metric<=1 then
            return metric,"fill"
        end
        return metric,"value"
    end

    return nil,nil
end

local function renderResource(w,y,resource,status,direction)
    local value,kind=resourceValue(status,resource.id)
    local label=tostring(resource.label or resource.id):upper()
    local prefix=direction=="input" and "IN  " or "OUT "

    if kind=="fill" then
        w:bar(y,prefix..label,value,direction=="input" and colors.lightBlue or colors.lime)
    else
        w:writeAt(3,y,prefix..label,colors.gray)
        w:writeAt(24,y,value==nil and "N/A" or tostring(value),colors.white)
    end
end

function M.render(target,definition,status,options)
    options=options or {}
    status=status or {}

    local w=widgets.new(target)
    if options.clear~=false then w:clear() end

    w:centered(1,("FACTORY %s  v%s"):format(
        tostring(definition.label or definition.id or "?"),
        tostring(status.version or "?")
    ),colors.cyan)

    w:writeAt(3,3,"RUNTIME",colors.gray)
    w:writeAt(14,3,tostring(status.runtime or "UNKNOWN"),
        widgets.stateColor(status.runtime))

    w:writeAt(3,4,"MODE",colors.gray)
    w:writeAt(14,4,tostring(status.mode or "UNKNOWN"),
        widgets.modeColor(status.mode))

    w:writeAt(3,5,"STATE",colors.gray)
    w:writeAt(14,5,tostring(status.state or "UNKNOWN"),
        widgets.stateColor(status.state))

    w:writeAt(3,6,"HEALTH",colors.gray)
    w:writeAt(14,6,tostring(status.health or "UNKNOWN"),
        widgets.healthColor(status.health))

    w:writeAt(3,7,"REASON",colors.gray)
    w:writeAt(14,7,tostring(status.reason or "-"),colors.lightGray)

    local y=9
    if #(definition.inputs or {})>0 then
        w:writeAt(3,y,"INPUTS",colors.cyan)
        y=y+1
        for _,resource in ipairs(definition.inputs or {}) do
            if y>=w.height-3 then break end
            renderResource(w,y,resource,status,"input")
            y=y+2
        end
    end

    if #(definition.outputs or {})>0 and y<w.height-3 then
        w:writeAt(3,y,"OUTPUTS",colors.cyan)
        y=y+1
        for _,resource in ipairs(definition.outputs or {}) do
            if y>=w.height-3 then break end
            renderResource(w,y,resource,status,"output")
            y=y+2
        end
    end

    local bounds={chains={}}

    if #(definition.chains or {})>0 and y<w.height-3 then
        w:writeAt(3,y,"SOUS-MODULES",colors.cyan)
        y=y+1

        local chainStatus=type(status.chains)=="table" and status.chains or {}

        for _,chain in ipairs(definition.chains or {}) do
            if y>=w.height-2 then break end

            local current=chainStatus[chain.id] or {}
            local enabled=current.enabled~=false
            local state=tostring(current.state or (enabled and "UNKNOWN" or "DISABLED"))

            w:writeAt(5,y,tostring(chain.label or chain.id),colors.white)
            w:writeAt(math.max(30,w.width-25),y,state,widgets.stateColor(state))

            if chain.controllable
                and options.allowChainControls
                and supports(definition,"chain.set_enabled") then
                local label=enabled and "[ OFF ]" or "[ ON ]"
                local x=w.width-#label-1
                bounds.chains[chain.id]=w:button(x,y,label,true,false)
                bounds.chains[chain.id].action="chain.set_enabled"
                bounds.chains[chain.id].chainId=chain.id
                bounds.chains[chain.id].targetEnabled=not enabled
            end

            y=y+1
        end
    end

    return bounds
end

return M
