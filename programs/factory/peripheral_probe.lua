-- Factory Control - Peripheral Probe
-- Read-only diagnostic tool for the H2/O2 prototype.

local function safeCall(device, method)
    if not device or type(device[method]) ~= "function" then
        return nil
    end

    local ok, result = pcall(device[method])
    if ok then
        return result
    end

    return "<error: " .. tostring(result) .. ">"
end

local function oneLine(value)
    if type(value) == "table" then
        return textutils.serialize(value, { compact = true })
    end
    return tostring(value)
end

local names = peripheral.getNames()
table.sort(names)

print("Factory Control - Peripheral Probe")
print(("Detected peripherals: %d"):format(#names))
print(("="):rep(38))

for _, name in ipairs(names) do
    local device = peripheral.wrap(name)
    local pType = peripheral.getType(name) or "unknown"

    print("")
    print(("[%s]"):format(name))
    print("Type: " .. tostring(pType))

    local methods = peripheral.getMethods(name) or {}
    table.sort(methods)
    print("Methods: " .. table.concat(methods, ", "))

    -- Common Mekanism telemetry. Only existing methods are called.
    local checks = {
        {"Stored", "getStored"},
        {"Capacity", "getCapacity"},
        {"Filled", "getFilledPercentage"},
        {"Input", "getInput"},
        {"InputFilled", "getInputFilledPercentage"},
        {"LeftOutput", "getLeftOutput"},
        {"LeftFilled", "getLeftOutputFilledPercentage"},
        {"RightOutput", "getRightOutput"},
        {"RightFilled", "getRightOutputFilledPercentage"},
        {"Energy", "getEnergy"},
        {"EnergyFilled", "getEnergyFilledPercentage"},
        {"EnergyUsage", "getEnergyUsage"},
        {"RedstoneMode", "getRedstoneMode"},
    }

    for _, check in ipairs(checks) do
        local value = safeCall(device, check[2])
        if value ~= nil then
            print(("  %-14s %s"):format(check[1] .. ":", oneLine(value)))
        end
    end
end

print("")
print(("="):rep(38))
print("Probe complete. No machine setting was changed.")
