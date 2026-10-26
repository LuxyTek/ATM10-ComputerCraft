local OWNER = "LuxyTek"
local REPO = "ATM10-ComputerCraft"
local BRANCH = "factory-proto-h2o2"
local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)

local files = {
    {"programs/factory/h2o2.lua", "/programs/factory/h2o2.lua", true},
    {"programs/factory/peripheral_probe.lua", "/programs/factory/peripheral_probe.lua", true},
    {"programs/factory/lib/updater.lua", "/programs/factory/lib/updater.lua", true},
    {"programs/factory/update_manifest.lua", "/programs/factory/update_manifest.lua", true},
    {"config/factory_h2o2.example.lua", "/config/factory_h2o2.lua", false},
}

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
end

local function install(remote, localPath, overwrite)
    if fs.exists(localPath) and not overwrite then
        print("Conserve : " .. localPath)
        return true
    end

    local response, err = http.get(BASE .. remote, nil, true)
    if not response then
        printError("Echec HTTP : " .. remote)
        if err then printError(err) end
        return false
    end

    local body = response.readAll()
    response.close()

    if remote:match("%.lua$") then
        local chunk, compileError = load(body, "@" .. remote)
        if not chunk then
            printError("Lua invalide : " .. remote)
            printError(compileError)
            return false
        end
    end

    ensureParent(localPath)
    local temp = localPath .. ".new"
    if fs.exists(temp) then fs.delete(temp) end

    local f = fs.open(temp, "w")
    if not f then return false end
    f.write(body)
    f.close()

    if fs.exists(localPath) then fs.delete(localPath) end
    fs.move(temp, localPath)

    print("Installe : " .. localPath)
    return true
end

print("Factory Control - installation V0.1")
print("-----------------------------------")

for _, entry in ipairs(files) do
    if not install(entry[1], entry[2], entry[3]) then
        error("Installation interrompue")
    end
end

print("")
print("Installation terminee.")
print("Lance : programs/factory/h2o2")
