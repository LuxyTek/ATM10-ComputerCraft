local OWNER = "LuxyTek"
local REPO = "ATM10-ComputerCraft"
local BRANCH = "main"
local BASE_URL = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/" .. BRANCH .. "/"

local args = { ... }
local installStartup = args[1] == "startup" or args[1] == "--startup"

local files = {
    { remote = "programs/power.lua", localPath = "/programs/power.lua", overwrite = true },
    { remote = "config/power.lua", localPath = "/config/power.lua", overwrite = false },
}

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function validateLua(remote, body)
    if not string.match(remote, "%.lua$") then
        return true
    end

    local chunk, err = load(body, "@" .. remote)
    if not chunk then
        return false, err
    end

    return true
end

local function download(remote, localPath, overwrite)
    ensureParent(localPath)

    if fs.exists(localPath) and not overwrite then
        print("Conserve : " .. localPath)
        return true
    end

    local response, err = http.get(BASE_URL .. remote)
    if not response then
        printError("Echec : " .. remote)
        if err then printError(err) end
        return false
    end

    local body = response.readAll()
    response.close()

    if not body or #body == 0 then
        printError("Fichier vide : " .. remote)
        return false
    end

    local valid, validationError = validateLua(remote, body)
    if not valid then
        printError("Lua invalide : " .. remote)
        if validationError then printError(validationError) end
        return false
    end

    local tempPath = localPath .. ".new"
    local backupPath = localPath .. ".bak"

    if fs.exists(tempPath) then fs.delete(tempPath) end

    local file = fs.open(tempPath, "w")
    if not file then
        printError("Impossible d'ecrire : " .. tempPath)
        return false
    end

    file.write(body)
    file.close()

    if fs.exists(backupPath) then fs.delete(backupPath) end

    if fs.exists(localPath) then
        local backupOK, backupError = pcall(fs.copy, localPath, backupPath)
        if not backupOK then
            fs.delete(tempPath)
            printError("Backup impossible : " .. localPath)
            if backupError then printError(backupError) end
            return false
        end
    end

    local replaceOK, replaceError = pcall(function()
        if fs.exists(localPath) then fs.delete(localPath) end
        fs.move(tempPath, localPath)
    end)

    if not replaceOK then
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

print("ATM10 ComputerCraft - installation")
print("----------------------------------")

for _, file in ipairs(files) do
    if not download(file.remote, file.localPath, file.overwrite) then
        error("Installation interrompue")
    end
end

if installStartup then
    if fs.exists("/startup.lua") then
        print("startup.lua existe deja : non modifie")
        print("Ajoute manuellement : shell.run(\"/programs/power.lua\")")
    else
        if not download("startup.lua", "/startup.lua", false) then
            error("Impossible d'installer le demarrage automatique")
        end
    end
end

print("")
print("Installation terminee.")
print("Lance le dashboard avec :")
print("programs/power")
