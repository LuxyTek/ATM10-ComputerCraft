local M = {}

local Widget = {}
Widget.__index = Widget

local function clamp01(value)
    if type(value) ~= "number" then return nil end
    return math.max(0, math.min(1, value))
end

function M.new(target)
    target = target or term.current()
    local width, height = target.getSize()

    return setmetatable({
        target=target,
        width=width,
        height=height,
    }, Widget)
end

function Widget:refreshSize()
    self.width, self.height = self.target.getSize()
    return self.width, self.height
end

function Widget:clear(bg)
    self.target.setBackgroundColor(bg or colors.black)
    self.target.setTextColor(colors.white)
    self.target.clear()
end

function Widget:writeAt(x,y,value,fg,bg)
    if y < 1 or y > self.height then return end

    x = math.max(1, math.floor(tonumber(x) or 1))
    if x > self.width then return end

    self.target.setCursorPos(x,y)
    self.target.setTextColor(fg or colors.white)
    self.target.setBackgroundColor(bg or colors.black)

    local available = self.width - x + 1
    self.target.write(tostring(value or ""):sub(1,available))
end

function Widget:centered(y,value,fg,bg)
    local text = tostring(value or "")
    local x = math.max(1, math.floor((self.width-#text)/2)+1)
    self:writeAt(x,y,text,fg,bg)
end

function Widget:percent(value, decimals)
    local fill = clamp01(value)
    if fill == nil then return "N/A" end
    decimals = tonumber(decimals) or 0
    return string.format("%."..decimals.."f%%", fill*100)
end

function Widget:bar(y,label,fill,color,options)
    options = options or {}
    fill = clamp01(fill) or 0

    local labelX = options.labelX or 2
    local barX = options.barX or 16
    local rightReserve = options.rightReserve or 9
    local barWidth = options.width or math.max(6,self.width-barX-rightReserve)

    self:writeAt(labelX,y,label or "",colors.white)

    local filled = math.floor(barWidth*fill+0.5)
    self:writeAt(barX,y,string.rep(" ",barWidth),colors.white,colors.gray)
    if filled > 0 then
        self:writeAt(barX,y,string.rep(" ",filled),colors.black,color or colors.lime)
    end

    self:writeAt(
        math.min(self.width,barX+barWidth+1),
        y,
        self:percent(fill,1),
        colors.white
    )
end

function Widget:box(x,y,width,height,title,color)
    width = math.max(4,math.floor(width))
    height = math.max(3,math.floor(height))
    color = color or colors.cyan

    local right = x+width-1
    local bottom = y+height-1
    local inner = math.max(2,width-2)
    local border = "+"..string.rep("-",inner).."+"

    self:writeAt(x,y,border,color)
    self:writeAt(x,bottom,border,color)

    for row=y+1,bottom-1 do
        self:writeAt(x,row,"|",color)
        self:writeAt(right,row,"|",color)
    end

    if title then
        local text=" "..tostring(title).." "
        local tx=x+math.max(1,math.floor((width-#text)/2))
        self:writeAt(tx,y,text,color,colors.black)
    end

    return {x1=x,x2=right,y1=y,y2=bottom}
end

function Widget:button(x,y,label,enabled,active)
    label=tostring(label or "")
    local fg,bg

    if enabled == false then
        fg,bg=colors.lightGray,colors.gray
    elseif active then
        fg,bg=colors.black,colors.lime
    else
        fg,bg=colors.white,colors.blue
    end

    self:writeAt(x,y,label,fg,bg)
    return {x1=x,x2=x+#label-1,y1=y,y2=y}
end

function M.stateColor(state)
    state=tostring(state or "")
    if state=="RUN" or state=="ACTIVE" or state=="OK" then return colors.lime end
    if state=="HOLD" or state=="WARN" then return colors.orange end
    if state=="STOP" or state=="FAULT" or state=="ABSENT" then return colors.red end
    if state=="SLEEP" then return colors.cyan end
    if state=="IDLE" then return colors.lightGray end
    return colors.white
end

function M.modeColor(mode)
    if mode=="AUTO" then return colors.lime end
    if mode=="MANUAL" then return colors.yellow end
    return colors.lightGray
end

function M.healthColor(health)
    if health=="OK" then return colors.lime end
    if health=="WARN" then return colors.orange end
    if health=="FAULT" then return colors.red end
    return colors.lightGray
end

function M.compact(value,suffix)
    if type(value) ~= "number" then return "N/A" end
    local abs=math.abs(value)
    local number

    if abs >= 1000000000 then number=("%.2f G"):format(value/1000000000)
    elseif abs >= 1000000 then number=("%.2f M"):format(value/1000000)
    elseif abs >= 1000 then number=("%.2f k"):format(value/1000)
    else number=("%.0f"):format(value) end

    return number..tostring(suffix or "")
end

function M.inside(bounds,x,y)
    return bounds
        and x>=bounds.x1 and x<=bounds.x2
        and y>=bounds.y1 and y<=bounds.y2
end

return M
