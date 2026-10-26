-- Factory Control - shared updater
-- Multi-file update engine with validation, backup and rollback.

local M = {}

local DEFAULTS = {
    owner = "LuxyTek",
    repo = "ATM10-ComputerCraft",
    branch = "factory-proto-h2o2",
    manifest = "programs/factory/update_manifest.lua",
    timeout = 12,
}

local function joinBase(owner, repo, branch)
    return ("https://raw.githubusercontent.com/%s/%s/%s/"):format(owner, repo, branch)
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function readHttp(url)
    local response, err = http.get(url, nil, true)
    if not response then
        return nil, err or "HTTP request failed"
    end

    local body = response.readAll()
    response.close()

    if not body or #body == 0 then
        return nil, "Empty response"
    end

    return body
end

local function validateLua(path, body)
    if not path:match("%.lua$") then
        return true
    end

    local chunk, err = load(body, "@" .. path)
    if not chunk then
        return false, err
    end

    return true
end

local function loadManifest(body)
    local chunk, err = load(body, "@factory-update-manifest")
    if not chunk then
        return nil, err
    end

    local ok, manifest = pcall(chunk)
    if not ok then
        return nil, manifest
    end

    if type(manifest) ~= "table" or type(manifest.files) ~= "table" then
        return nil, "Invalid update manifest"
    end

    return manifest
end

local function cleanupStaged(staged)
    for _, entry in ipairs(staged) do
        if fs.exists(entry.tempPath) then
            fs.delete(entry.tempPath)
        end
    end
end

local function cleanupBackups(staged)
    for _, entry in ipairs(staged) do
        if fs.exists(entry.backupPath) then
            fs.delete(entry.backupPath)
        end
    end
end

local function rollback(staged)
    for _, entry in ipairs(staged) do
        if fs.exists(entry.backupPath) then
            if fs.exists(entry.localPath) then
                fs.delete(entry.localPath)
            end
            fs.copy(entry.backupPath, entry.localPath)
        elseif entry.didNotExistBefore and fs.exists(entry.localPath) then
            fs.delete(entry.localPath)
        end
    end

    cleanupStaged(staged)
    cleanupBackups(staged)
end

function M.update(options)
    options = options or {}

    local owner = options.owner or DEFAULTS.owner
    local repo = options.repo or DEFAULTS.repo
    local branch = options.branch or DEFAULTS.branch
    local manifestPath = options.manifest or DEFAULTS.manifest

    local baseUrl = joinBase(owner, repo, branch)

    local manifestBody, manifestError = readHttp(baseUrl .. manifestPath)
    if not manifestBody then
        return false, "Manifest download failed: " .. tostring(manifestError)
    end

    local manifest, parseError = loadManifest(manifestBody)
    if not manifest then
        return false, "Manifest invalid: " .. tostring(parseError)
    end

    local staged = {}

    -- Phase 1: download and validate everything before touching live files.
    for _, file in ipairs(manifest.files) do
        if type(file.remote) ~= "string" or type(file.localPath) ~= "string" then
            cleanupStaged(staged)
            return false, "Malformed file entry in manifest"
        end

        local body, downloadError = readHttp(baseUrl .. file.remote)
        if not body then
            cleanupStaged(staged)
            return false, ("Download failed for %s: %s"):format(file.remote, tostring(downloadError))
        end

        local valid, validationError = validateLua(file.remote, body)
        if not valid then
            cleanupStaged(staged)
            return false, ("Lua validation failed for %s: %s"):format(file.remote, tostring(validationError))
        end

        ensureParent(file.localPath)

        local tempPath = file.localPath .. ".new"
        local backupPath = file.localPath .. ".bak"

        if fs.exists(tempPath) then fs.delete(tempPath) end

        local handle = fs.open(tempPath, "w")
        if not handle then
            cleanupStaged(staged)
            return false, "Cannot write temporary file: " .. tempPath
        end

        handle.write(body)
        handle.close()

        table.insert(staged, {
            remote = file.remote,
            localPath = file.localPath,
            tempPath = tempPath,
            backupPath = backupPath,
            didNotExistBefore = not fs.exists(file.localPath),
        })
    end

    -- Phase 2: create backups for all current files.
    for _, entry in ipairs(staged) do
        if fs.exists(entry.backupPath) then
            fs.delete(entry.backupPath)
        end

        if fs.exists(entry.localPath) then
            local ok, backupError = pcall(fs.copy, entry.localPath, entry.backupPath)
            if not ok then
                rollback(staged)
                return false, ("Backup failed for %s: %s"):format(entry.localPath, tostring(backupError))
            end
        end
    end

    -- Phase 3: replace live files.
    for _, entry in ipairs(staged) do
        local ok, replaceError = pcall(function()
            if fs.exists(entry.localPath) then
                fs.delete(entry.localPath)
            end
            fs.move(entry.tempPath, entry.localPath)
        end)

        if not ok then
            rollback(staged)
            return false, ("Replacement failed for %s: %s"):format(entry.localPath, tostring(replaceError))
        end
    end

    cleanupBackups(staged)

    return true, manifest.version or "unknown"
end

function M.getDefaults()
    return {
        owner = DEFAULTS.owner,
        repo = DEFAULTS.repo,
        branch = DEFAULTS.branch,
        manifest = DEFAULTS.manifest,
        timeout = DEFAULTS.timeout,
    }
end

return M
