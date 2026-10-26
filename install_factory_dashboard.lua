local OWNER = "LuxyTek"
local REPO = "ATM10-ComputerCraft"
local BRANCH = "factory-proto-h2o2"
local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)

local files = {
    {"programs/factory/dashboard.lua", "/programs/factory/dashboard.lua", true},
    {"config/factory_dashboard.example.lua", "/config/factory_dashboard.lua", false},
}

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
end

local function download(remote)
    local url = BASE .. remote
    local queued, err = http.request({ url = url, method = "GET", redirect = true, timeout = 10 })
    if not queued then return nil, err or "HTTP request refused" end

    local timer = os.startTimer(12)
    while true do
        local event, p1, p2 = os.pullEvent()

        if event == "http_success" and p1 == url then
            local response = p2
            local body = response.readAll()
            response.close()
            return body
        elseif event == "http_failure" and p1 == url then
            return nil, p2 or "HTTP failure"
        elseif event == "timer" and p1 == timer then
            return nil, "HTTP timeout"
        end
    end
end

local function install(remote, localPath, overwrite)
    if fs.exists(localPath) and not overwrite then
        print("Conserve : " .. localPath)
        return true
    end

    local body, err = download(remote)
    if not body or #body == 0 then
        printError("Echec : " .. remote)
        if err then printError(err) end
        return false
    end

    local chunk, compileError = load(body, "@" .. remote)
    if remote:match("%.lua$") and not chunk then
        printError("Lua invalide : " .. remote)
        printError(compileError)
        return false
    end

    ensureParent(localPath)

    local tempPath = localPath .. ".new"
    if fs.exists(tempPath) then fs.delete(tempPath) end

    local handle = fs.open(tempPath, "w")
    handle.write(body)
    handle.close()

    if fs.exists(localPath) then fs.delete(localPath) end
    fs.move(tempPath, localPath)

    print("Installe : " .. localPath)
    return true
end

print("Factory Dashboard - installation")
print("--------------------------------")

for _, entry in ipairs(files) do
    if not install(entry[1], entry[2], entry[3]) then
        error("Installation interrompue")
    end
end

print("")
print("Installation terminee.")
print("Lancement : programs/factory/dashboard")
