local OWNER="LuxyTek"
local REPO="ATM10-ComputerCraft"
local BRANCH="refactor/factory-v2"

local ROOT=("https://raw.githubusercontent.com/%s/%s/%s/"):format(
    OWNER,REPO,BRANCH
)

local UPDATER_REMOTE="programs/factory/dev/dev_updater.lua"
local UPDATER_LOCAL="/programs/factory/dev/dev_updater.lua"

local STARTUP_PATH="/startup.lua"
local STARTUP_BACKUP="/startup.factory_v2_dev.bak"
local STARTUP_BODY='shell.run("/startup_factory_v2_dev.lua")\n'

local function ensureParent(path)
    local parent=fs.getDir(path)
    if parent~="" and not fs.exists(parent) then fs.makeDir(parent) end
end

local function download(remote,localPath)
    ensureParent(localPath)

    local response,err=http.get(ROOT..remote)
    if not response then
        return false,err or "HTTP failure"
    end

    local body=response.readAll()
    response.close()

    if not body or #body==0 then
        return false,"empty response"
    end

    if remote:match("%.lua$") then
        local chunk,loadError=load(body,"@"..remote)
        if not chunk then return false,loadError end
    end

    local temp=localPath..".new"
    if fs.exists(temp) then fs.delete(temp) end

    local handle=fs.open(temp,"w")
    if not handle then return false,"cannot write "..temp end
    handle.write(body)
    handle.close()

    if fs.exists(localPath) then fs.delete(localPath) end
    fs.move(temp,localPath)

    return true
end

local function readFile(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local handle=fs.open(path,"r")
    if not handle then return nil end
    local body=handle.readAll()
    handle.close()
    return body
end

local function installStartup()
    local current=readFile(STARTUP_PATH)

    if current~=nil and not current:find(
        '/startup_factory_v2_dev.lua',
        1,
        true
    ) then
        if not fs.exists(STARTUP_BACKUP) then
            fs.copy(STARTUP_PATH,STARTUP_BACKUP)
            print("Backup startup: "..STARTUP_BACKUP)
        else
            print("Backup startup deja present.")
        end
    end

    local handle=fs.open(STARTUP_PATH,"w")
    if not handle then return false,"cannot write "..STARTUP_PATH end
    handle.write(STARTUP_BODY)
    handle.close()

    return true
end

print("Factory V2 Dev - installation")
print("Branche: "..BRANCH)
print("")

print("Bootstrap updater...")
local ok,err=download(UPDATER_REMOTE,UPDATER_LOCAL)
if not ok then
    printError("Echec bootstrap updater: "..tostring(err))
    return false
end

local loaded,updater=pcall(dofile,UPDATER_LOCAL)
if not loaded or type(updater)~="table" or type(updater.update)~="function" then
    printError("Updater V2 invalide.")
    return false
end

local function progress(stage,current,total,label)
    if stage=="download" then
        print(("[%d/%d] %s"):format(current,total,tostring(label)))
    elseif stage=="install" then
        print(("Install %d/%d"):format(current,total))
    else
        print(tostring(stage):upper().." "..tostring(label or ""))
    end
end

local updateOK,versionOrError=updater.update(progress)
if not updateOK then
    printError("Echec mise a jour V2:")
    printError(tostring(versionOrError))
    return false
end

local startupOK,startupError=installStartup()
if not startupOK then
    printError("Fichiers V2 installes, mais startup non installe:")
    printError(tostring(startupError))
    print("Lancer: /programs/factory/dev/dev_panel.lua")
    return false
end

print("")
print("Factory V2 Dev installe: "..tostring(versionOrError))
print("Demarrage automatique du panneau tactile active.")
print("Redemarrage...")

sleep(1)
os.reboot()
