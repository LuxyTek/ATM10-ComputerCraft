-- Factory Control - Peripheral Probe
-- Compact on-screen diagnostic + optional full report file.
-- Read-only: no machine setting is changed.

local REPORT_PATH = "/factory_probe.txt"
local args = { ... }
local showFull = args[1] == "full" or args[1] == "--full"

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

local function hasMethod(methods, target)
    for _, method in ipairs(methods) do
        if method == target then return true end
    end
    return false
end

local function collectTelemetry(device, methods)
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

    local values = {}

    for _, check in ipairs(checks) do
        if hasMethod(methods, check[2]) then
            local value = safeCall(device, check[2])
            if value ~= nil then
                table.insert(values, { label = check[1], value = value })
            end
        end
    end

    return values
end

local function writeLine(handle, text)
    handle.write((text or "") .. "\n")
end

local names = peripheral.getNames()
table.sort(names)

local report = fs.open(REPORT_PATH, "w")
if not report then
    error("Impossible d'ecrire " .. REPORT_PATH)
end

writeLine(report, "Factory Control - Peripheral Probe")
writeLine(report, "Detected peripherals: " .. #names)
writeLine(report, ("="):rep(60))

print("Factory Probe - resume")
print(("="):rep(36))

for _, name in ipairs(names) do
    local device = peripheral.wrap(name)
    local pType = peripheral.getType(name) or "unknown"
    local methods = peripheral.getMethods(name) or {}
    table.sort(methods)

    local telemetry = collectTelemetry(device, methods)

    -- Compact output on screen.
    print("")
    print(name)
    print("  Type: " .. tostring(pType))

    for _, entry in ipairs(telemetry) do
        -- Only compact percentages/identity-ish values on screen.
        if entry.label == "Filled"
            or entry.label == "InputFilled"
            or entry.label == "LeftFilled"
            or entry.label == "RightFilled"
            or entry.label == "EnergyFilled"
            or entry.label == "EnergyUsage"
            or entry.label == "RedstoneMode"
            or entry.label == "Stored"
            or entry.label == "LeftOutput"
            or entry.label == "RightOutput"
            or entry.label == "Input" then
            print(("  %-12s %s"):format(entry.label .. ":", oneLine(entry.value)))
        end
    end

    -- Full report saved to disk.
    writeLine(report, "")
    writeLine(report, "[" .. name .. "]")
    writeLine(report, "Type: " .. tostring(pType))
    writeLine(report, "Methods: " .. table.concat(methods, ", "))

    for _, entry in ipairs(telemetry) do
        writeLine(report, ("  %-14s %s"):format(entry.label .. ":", oneLine(entry.value)))
    end
end

writeLine(report, "")
writeLine(report, ("="):rep(60))
writeLine(report, "Probe complete. No machine setting was changed.")
report.close()

print("")
print(("="):rep(36))
print("Rapport complet: " .. REPORT_PATH)
print("Aucune configuration modifiee.")

if showFull then
    print("")
    shell.run("type", REPORT_PATH)
end
