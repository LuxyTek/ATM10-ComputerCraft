local widgets = dofile("/programs/factory/ui/widgets.lua")

local M = {}

local function statusFor(statuses,id)
    return type(statuses)=="table" and statuses[id] or {}
end

local function deriveLevels(definitions,edges)
    local byId={}
    local indegree={}
    local outgoing={}

    for _,definition in ipairs(definitions or {}) do
        byId[definition.id]=definition
        indegree[definition.id]=0
        outgoing[definition.id]={}
    end

    for _,edge in ipairs(edges or {}) do
        if byId[edge.from] and byId[edge.to] then
            indegree[edge.to]=(indegree[edge.to] or 0)+1
            table.insert(outgoing[edge.from],edge.to)
        end
    end

    local queue={}
    local level={}
    for id,count in pairs(indegree) do
        if count==0 then
            table.insert(queue,id)
            level[id]=1
        end
    end
    table.sort(queue)

    local head=1
    while head<=#queue do
        local id=queue[head]
        head=head+1

        for _,target in ipairs(outgoing[id] or {}) do
            level[target]=math.max(level[target] or 1,(level[id] or 1)+1)
            indegree[target]=indegree[target]-1
            if indegree[target]==0 then table.insert(queue,target) end
        end
    end

    -- Cycles or isolated unresolved nodes fall back to level 1.
    for id in pairs(byId) do
        if level[id]==nil then level[id]=1 end
    end

    return level
end

local function groupByLevel(definitions,levels)
    local groups={}
    local maxLevel=1

    for _,definition in ipairs(definitions or {}) do
        local level=levels[definition.id] or 1
        groups[level]=groups[level] or {}
        table.insert(groups[level],definition)
        maxLevel=math.max(maxLevel,level)
    end

    for _,group in pairs(groups) do
        table.sort(group,function(a,b)
            return tostring(a.label or a.id)<tostring(b.label or b.id)
        end)
    end

    return groups,maxLevel
end

local function drawNode(w,x,y,width,definition,status)
    local box=w:box(x,y,width,7,definition.label or definition.id,colors.cyan)

    w:writeAt(x+2,y+1,"RUN",colors.gray)
    w:writeAt(x+9,y+1,tostring(status.runtime or "N/A"),
        widgets.stateColor(status.runtime))

    w:writeAt(x+2,y+2,"MODE",colors.gray)
    w:writeAt(x+9,y+2,tostring(status.mode or "N/A"),
        widgets.modeColor(status.mode))

    w:writeAt(x+2,y+3,"STATE",colors.gray)
    w:writeAt(x+9,y+3,tostring(status.state or "N/A"),
        widgets.stateColor(status.state))

    w:writeAt(x+2,y+4,"HEALTH",colors.gray)
    w:writeAt(x+9,y+4,tostring(status.health or "N/A"),
        widgets.healthColor(status.health))

    return box
end

function M.layout(definitions,edges,width,height)
    local levels=deriveLevels(definitions,edges)
    local groups,maxLevel=groupByLevel(definitions,levels)

    local nodeWidth=math.max(16,math.min(22,math.floor((width-2)/math.max(1,maxLevel))-2))
    local nodeHeight=7
    local positions={}

    for level=1,maxLevel do
        local group=groups[level] or {}
        local x=2+(level-1)*math.floor((width-2)/math.max(1,maxLevel))

        for index,definition in ipairs(group) do
            local y=3+(index-1)*(nodeHeight+2)
            if y+nodeHeight-1<=height-5 then
                positions[definition.id]={
                    x=x,
                    y=y,
                    width=nodeWidth,
                    height=nodeHeight,
                    level=level,
                }
            end
        end
    end

    return positions
end

function M.render(target,registry,statuses,options)
    options=options or {}

    local w=widgets.new(target)
    if options.clear~=false then w:clear() end

    w:centered(1,"FACTORY FLOW MAP V2",colors.cyan)

    local definitions=registry:list()
    local edges=registry:topology()
    local positions=M.layout(definitions,edges,w.width,w.height)
    local bounds={modules={}}

    for _,definition in ipairs(definitions) do
        local pos=positions[definition.id]
        if pos then
            bounds.modules[definition.id]=drawNode(
                w,pos.x,pos.y,pos.width,definition,statusFor(statuses,definition.id)
            )
        end
    end

    local edgeY=math.max(3,w.height-math.min(#edges+2,8))
    w:writeAt(2,edgeY,"RESOURCE LINKS",colors.cyan)
    edgeY=edgeY+1

    for _,edge in ipairs(edges) do
        if edgeY>=w.height then break end

        local producer=registry:get(edge.from)
        local consumer=registry:get(edge.to)
        local text=("%s --%s--> %s"):format(
            tostring(producer and producer.label or edge.from),
            tostring(edge.resource),
            tostring(consumer and consumer.label or edge.to)
        )

        w:writeAt(3,edgeY,text,colors.lightGray)
        edgeY=edgeY+1
    end

    return bounds
end

return M
