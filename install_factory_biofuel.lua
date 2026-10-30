local OWNER = "LuxyTek"
local REPO = "ATM10-ComputerCraft"
local BRANCH = "factory-proto-h2o2"
local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)

local files = {
    {"programs/factory/biofuel.lua", "/programs/factory/biofuel.lua", true},
    {"programs/factory/lib/updater.lua", "/programs/factory/lib/updater.lua", true},
    {"programs/factory/biofuel_update_manifest.lua", "/programs/factory/biofuel_update_manifest.lua", true},
    {"config/factory_biofuel.example.lua", "/config/factory_biofuel.lua", false},
    {"startup_factory_biofuel.lua", "/startup.lua", true},
}

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function download(remote)
    local url = BASE .. remote

    local queued, requestError = http.request({
        url = url,
        method = "GET",
        redirect = true,
        timeout = 10,
    })

    if not queued then
        return nil, requestError or "HTTP request refused"
    end

    local timeoutTimer = os.startTimer(12)

    while true do
        local event, p1, p2 = os.pullEvent()

        if event == "http_success" and p1 == url then
            local response = p2
            local body = response.readAll()
            response.close()
            return body

        elseif event == "http_failure" and p1 == url then
            return nil, p2 or "HTTP failure"

        elseif event == "timer" and p1 == timeoutTimer then
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

    if remote:match("%.lua$") then
        local chunk, compileError = load(body, "@" .. remote)

        if not chunk then
            printError("Lua invalide : " .. remote)
            printError(compileError)
            return false
        end
    end

    ensureParent(localPath)

    local tempPath = localPath .. ".new"
    local backupPath = localPath .. ".bak"

    if fs.exists(tempPath) then fs.delete(tempPath) end

    local handle = fs.open(tempPath, "w")
    if not handle then
        printError("Impossible d'ecrire : " .. tempPath)
        return false
    end

    handle.write(body)
    handle.close()

    if fs.exists(backupPath) then fs.delete(backupPath) end

    if fs.exists(localPath) then
        local ok, backupError = pcall(fs.copy, localPath, backupPath)
        if not ok then
            fs.delete(tempPath)
            printError("Backup impossible : " .. localPath)
            if backupError then printError(backupError) end
            return false
        end
    end

    local ok, replaceError = pcall(function()
        if fs.exists(localPath) then fs.delete(localPath) end
        fs.move(tempPath, localPath)
    end)

    if not ok then
        if fs.exists(backupPath) then
            if fs.exists(localPath) then fs.delete(localPath) end
            fs.copy(backupPath, localPath)
        end

        if fs.exists(tempPath) then fs.delete(tempPath) end

        printError("Remplacement impossible : " .. localPath)
        if replaceError then printError(replaceError) end
        return false
    end

    if fs.exists(backupPath) then fs.delete(backupPath) end

    print("Installe : " .. localPath)
    return true
end

print("Factory BIOFUEL - installation")
print("------------------------------")

for _, entry in ipairs(files) do
    if not install(entry[1], entry[2], entry[3]) then
        error("Installation interrompue")
    end
end

print("")
print("Installation terminee.")
print("Le programme demarrera automatiquement au prochain reboot.")
print("Lancement immediat : programs/factory/biofuel")
