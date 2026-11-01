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

local function resourceDescriptor(definition,collectionName,resourceId)
    for _,resource in ipairs(definition[collectionName] or {}) do
        if resource.id==resourceId then return resource end
    end
    return nil
end

local function resourceLabel(registry,edge)
    local producer=registry:get(edge.from)
    local consumer=registry:get(edge.to)

    local descriptor=
        producer and resourceDescriptor(producer,"outputs",edge.resource)
        or consumer and resourceDescriptor(consumer,"inputs",edge.resource)
        or nil

    local label=descriptor and descriptor.label or edge.resource
    return tostring(label or "?"):gsub("_"," "):upper()
end

local function resourceFill(status,resourceId)
    status=type(status)=="table" and status or {}

    local resources=type(status.resources)=="table" and status.resources or {}
    local resource=resources[resourceId]

    if type(resource)=="table" and type(resource.fill)=="number" then
        return math.max(0,math.min(1,resource.fill))
    end

    local metrics=type(status.metrics)=="table" and status.metrics or {}
    local metric=metrics[resourceId]
    if type(metric)=="number" and metric>=0 and metric<=1 then
        return metric
    end

    return nil
end

local function linkColor(sourceStatus,targetStatus,fill)
    sourceStatus=type(sourceStatus)=="table" and sourceStatus or {}
    targetStatus=type(targetStatus)=="table" and targetStatus or {}

    if sourceStatus.health=="FAULT" or targetStatus.health=="FAULT" then
        return colors.red
    end
    if sourceStatus.health=="WARN" or targetStatus.health=="WARN" then
        return colors.orange
    end

    if type(fill)=="number" then
        if fill<=0.10 then return colors.red end
        if fill<=0.20 then return colors.orange end
        return colors.lime
    end

    if sourceStatus.health=="OK" and targetStatus.health=="OK" then
        return colors.lime
    end

    return colors.lightGray
end

local function horizontal(w,x1,x2,y,color,arrow)
    if y<1 or y>w.height then return end
    if x1==x2 then
        w:writeAt(x1,y,arrow or "-",color)
        return
    end

    local left=math.min(x1,x2)
    local right=math.max(x1,x2)
    w:writeAt(left,y,string.rep("-",math.max(1,right-left+1)),color)

    if arrow==">" then
        w:writeAt(right,y,">",color)
    elseif arrow=="<" then
        w:writeAt(left,y,"<",color)
    end
end

local function vertical(w,x,y1,y2,color)
    local top=math.min(y1,y2)
    local bottom=math.max(y1,y2)
    for y=top,bottom do
        w:writeAt(x,y,"|",color)
    end
end

local function edgeText(label,fill)
    if type(fill)=="number" then
        return ("%s %.0f%%"):format(label,fill*100)
    end
    return label
end

local function drawEdge(w,registry,statuses,positions,edge,lane)
    local source=positions[edge.from]
    local target=positions[edge.to]
    if not source or not target then return end

    local sourceStatus=statusFor(statuses,edge.from)
    local targetStatus=statusFor(statuses,edge.to)
    local fill=resourceFill(sourceStatus,edge.resource)
        or resourceFill(targetStatus,edge.resource)

    local color=linkColor(sourceStatus,targetStatus,fill)
    local label=edgeText(resourceLabel(registry,edge),fill)

    local sy=source.y+math.floor(source.height/2)
    local ty=target.y+math.floor(target.height/2)

    local sourceRight=source.x+source.width
    local sourceLeft=source.x-1
    local targetRight=target.x+target.width
    local targetLeft=target.x-1

    local goingRight=target.x>source.x
    local sx=goingRight and sourceRight or sourceLeft
    local tx=goingRight and targetLeft or targetRight
    local arrow=goingRight and ">" or "<"

    if sy==ty then
        horizontal(w,sx,tx,sy,color,arrow)

        local left=math.min(sx,tx)
        local right=math.max(sx,tx)
        local span=right-left+1
        if #label+2<span then
            local lx=left+math.floor((span-#label)/2)
            w:writeAt(lx,sy,label,color,colors.black)
        elseif sy>2 then
            w:writeAt(left,sy-1,label,color)
        end
        return
    end

    local left=math.min(sx,tx)
    local right=math.max(sx,tx)
    local joinX=math.floor((left+right)/2)

    -- Spread parallel links slightly when there is room, while keeping
    -- routing generic and independent from module identities.
    if lane and lane>1 then
        local direction=(lane%2==0) and 1 or -1
        local offset=math.floor(lane/2)*direction
        joinX=math.max(left+1,math.min(right-1,joinX+offset))
    end

    horizontal(w,sx,joinX,sy,color,nil)
    vertical(w,joinX,sy,ty,color)
    horizontal(w,joinX,tx,ty,color,arrow)
    w:writeAt(joinX,sy,"+",color)
    w:writeAt(joinX,ty,"+",color)

    local labelY=math.min(sy,ty)-1
    if labelY>=2 then
        local available=math.max(1,math.abs(joinX-sx))
        local lx=math.min(sx,joinX)
        if #label+1<=available then
            lx=lx+math.max(0,math.floor((available-#label)/2))
        end
        w:writeAt(lx,labelY,label,color)
    end
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

    local definitions=registry:list()
    local edges=registry:topology()
    local positions=M.layout(definitions,edges,w.width,w.height)
    local bounds={modules={}}

    w:centered(
        1,
        ("FACTORY FLOW MAP V2.1   LINKS:%d"):format(#edges),
        colors.cyan
    )

    for _,definition in ipairs(definitions) do
        local pos=positions[definition.id]
        if pos then
            bounds.modules[definition.id]=drawNode(
                w,pos.x,pos.y,pos.width,definition,statusFor(statuses,definition.id)
            )
        end
    end

    -- Draw topology links after nodes. Endpoints are placed one character
    -- outside module borders, so routes stay visible without overwriting
    -- module contents.
    local pairLane={}
    for _,edge in ipairs(edges) do
        local key=tostring(edge.from).."->"..tostring(edge.to)
        pairLane[key]=(pairLane[key] or 0)+1
        drawEdge(
            w,
            registry,
            statuses,
            positions,
            edge,
            pairLane[key]
        )
    end

    return bounds
end

return M
