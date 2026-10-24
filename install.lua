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

    local file = fs.open(localPath, "w")
    if not file then
        printError("Impossible d'ecrire : " .. localPath)
        return false
    end

    file.write(body)
    file.close()
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
