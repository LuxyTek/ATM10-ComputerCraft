local M = {}

local OWNER="LuxyTek"
local REPO="ATM10-ComputerCraft"
local BRANCH="refactor/factory-v2"
local MANIFEST="programs/factory/dev/dev_manifest.lua"
local TIMEOUT=12

local function rootUrl()
    return ("https://raw.githubusercontent.com/%s/%s/%s/"):format(
        OWNER,REPO,BRANCH
    )
end

local function ensureParent(path)
    local parent=fs.getDir(path)
    if parent~="" and not fs.exists(parent) then fs.makeDir(parent) end
end

local function requestBody(url)
    local queued,requestError=http.request({
        url=url,
        method="GET",
        redirect=true,
        timeout=math.max(1,TIMEOUT-2),
    })

    if not queued then return nil,requestError or "HTTP request refused" end

    local timer=os.startTimer(TIMEOUT)

    while true do
        local event,p1,p2=os.pullEvent()

        if event=="http_success" and p1==url then
            local response=p2
            local body=response.readAll()
            response.close()
            if not body or #body==0 then return nil,"Empty response" end
            return body

        elseif event=="http_failure" and p1==url then
            return nil,p2 or "HTTP failure"

        elseif event=="timer" and p1==timer then
            return nil,"HTTP timeout"
        end
    end
end

local function validateLua(path,body)
    if not path:match("%.lua$") then return true end
    local chunk,err=load(body,"@"..path)
    if not chunk then return false,err end
    return true
end

local function parseManifest(body)
    local chunk,err=load(body,"@factory-v2-dev-manifest")
    if not chunk then return nil,err end

    local ok,manifest=pcall(chunk)
    if not ok then return nil,manifest end
    if type(manifest)~="table" or type(manifest.files)~="table" then
        return nil,"Invalid dev manifest"
    end

    return manifest
end

local function cleanup(staged,field)
    for _,entry in ipairs(staged) do
        local path=entry[field]
        if path and fs.exists(path) then fs.delete(path) end
    end
end

local function rollback(staged)
    for _,entry in ipairs(staged) do
        if fs.exists(entry.backupPath) then
            if fs.exists(entry.localPath) then fs.delete(entry.localPath) end
            fs.copy(entry.backupPath,entry.localPath)
        elseif entry.didNotExistBefore and fs.exists(entry.localPath) then
            fs.delete(entry.localPath)
        end
    end

    cleanup(staged,"tempPath")
    cleanup(staged,"backupPath")
end

function M.update(progress)
    local function report(stage,current,total,label)
        if type(progress)=="function" then
            pcall(progress,stage,current,total,label)
        end
    end

    report("manifest",0,0,"MANIFEST")

    local manifestBody,manifestError=requestBody(rootUrl()..MANIFEST)
    if not manifestBody then
        return false,"Manifest: "..tostring(manifestError)
    end

    local manifest,parseError=parseManifest(manifestBody)
    if not manifest then
        return false,"Manifest invalid: "..tostring(parseError)
    end

    local staged={}
    local total=#manifest.files

    for index,file in ipairs(manifest.files) do
        if type(file.remote)~="string" or type(file.localPath)~="string" then
            cleanup(staged,"tempPath")
            return false,"Malformed manifest entry"
        end

        report("download",index,total,file.remote)

        local body,downloadError=requestBody(rootUrl()..file.remote)
        if not body then
            cleanup(staged,"tempPath")
            return false,("%s: %s"):format(file.remote,tostring(downloadError))
        end

        local valid,validationError=validateLua(file.remote,body)
        if not valid then
            cleanup(staged,"tempPath")
            return false,("%s invalid: %s"):format(
                file.remote,tostring(validationError)
            )
        end

        ensureParent(file.localPath)

        local tempPath=file.localPath..".new"
        local backupPath=file.localPath..".bak"

        if fs.exists(tempPath) then fs.delete(tempPath) end

        local handle=fs.open(tempPath,"w")
        if not handle then
            cleanup(staged,"tempPath")
            return false,"Cannot write "..tempPath
        end

        handle.write(body)
        handle.close()

        table.insert(staged,{
            localPath=file.localPath,
            tempPath=tempPath,
            backupPath=backupPath,
            didNotExistBefore=not fs.exists(file.localPath),
        })
    end

    report("backup",0,total,"BACKUP")

    for _,entry in ipairs(staged) do
        if fs.exists(entry.backupPath) then fs.delete(entry.backupPath) end

        if fs.exists(entry.localPath) then
            local ok,backupError=pcall(fs.copy,entry.localPath,entry.backupPath)
            if not ok then
                rollback(staged)
                return false,("Backup %s: %s"):format(
                    entry.localPath,tostring(backupError)
                )
            end
        end
    end

    for index,entry in ipairs(staged) do
        report("install",index,total,entry.localPath)

        local ok,replaceError=pcall(function()
            if fs.exists(entry.localPath) then fs.delete(entry.localPath) end
            fs.move(entry.tempPath,entry.localPath)
        end)

        if not ok then
            rollback(staged)
            return false,("Replace %s: %s"):format(
                entry.localPath,tostring(replaceError)
            )
        end
    end

    cleanup(staged,"backupPath")
    report("done",total,total,manifest.version or "unknown")

    return true,manifest.version or "unknown"
end

function M.info()
    return {
        owner=OWNER,
        repo=REPO,
        branch=BRANCH,
        manifest=MANIFEST,
    }
end

return M
