local STATUS_PROTOCOL = "factory.status.v1"

local function openRednet()
    local opened = 0

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            if not rednet.isOpen(name) then
                local ok = pcall(rednet.open, name)
                if ok then opened = opened + 1 end
            else
                opened = opened + 1
            end
        end
    end

    return opened
end

if openRednet() == 0 then
    error("Aucun modem Rednet disponible")
end

local tick = 0

print("Factory Status Simulator")
print("Protocol: " .. STATUS_PROTOCOL)
print("Ctrl+T pour arreter")

while true do
    tick = tick + 1

    local h2 = math.min(0.98, 0.20 + (tick % 20) * 0.035)
    local o2 = math.min(0.98, 0.10 + (tick % 25) * 0.025)

    local active = 3
    local state = "RUN"
    local reason = ("LOCAL H2 %.0f O2 %.0f"):format(h2 * 100, o2 * 100)

    local demand = math.min(h2, o2)

    if h2 >= 0.95 and o2 >= 0.95 then
        active = 0
        state = "HOLD"
        reason = "FULL BUFFER"
    elseif demand >= 0.70 then
        active = 1
    elseif demand >= 0.30 then
        active = 2
    end

    rednet.broadcast({
        contract = 1,
        id = "sim-h2o2",
        label = "H2/O2 SIM",
        type = "process",
        version = "sim",

        mode = "AUTO",
        state = state,
        health = "OK",
        reason = reason,

        activeLines = active,
        totalLines = 3,

        metrics = {
            water = 0.98,
            hydrogen = h2,
            oxygen = o2,
        },

        alarms = {},
    }, STATUS_PROTOCOL)

    print(("Broadcast #%d - %d/3 lines"):format(tick, active))
    sleep(2)
end
