-- Factory Control - shared updater
-- Event-driven multi-file updater with validation, backup and rollback.

local M = {}

local DEFAULTS = {
    owner = "LuxyTek",
    repo = "ATM10-ComputerCraft",
    branch = "factory-proto-h2o2",
    manifest = "programs/factory/update_manifest.lua",
    timeout = 12,
}

local function baseUrl(owner, repo, branch)
    return ("https://raw.githubusercontent.com/%s/%s/%s/"):format(owner, repo, branch)
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
end

local function requestBody(url, timeoutSeconds)
    local queued, requestError = http.request({
        url = url,
        method = "GET",
        redirect = true,
        timeout = math.max(1, timeoutSeconds - 2),
    })

    if not queued then
        return nil, requestError or "HTTP request refused"
    end

    local timeoutTimer = os.startTimer(timeoutSeconds)

    while true do
        local event, p1, p2 = os.pullEvent()

        if event == "http_success" and p1 == url then
            local response = p2
            local body = response.readAll()
            response.close()

            if not body or #body == 0 then
                return nil, "Empty response"
            end

            return body

        elseif event == "http_failure" and p1 == url then
            return nil, p2 or "HTTP failure"

        elseif event == "timer" and p1 == timeoutTimer then
            return nil, "HTTP timeout"
        end
    end
end

local function validateLua(path, body)
    if not path:match("%.lua$") then return true end

    local chunk, err = load(body, "@" .. path)

    if not chunk then
        return false, err
    end

    return true
end

local function parseManifest(body)
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

local function cleanupTemps(staged)
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

    cleanupTemps(staged)
    cleanupBackups(staged)
end

function M.update(options)
    options = options or {}

    local owner = options.owner or DEFAULTS.owner
    local repo = options.repo or DEFAULTS.repo
    local branch = options.branch or DEFAULTS.branch
    local manifestPath = options.manifest or DEFAULTS.manifest
    local timeout = options.timeout or DEFAULTS.timeout

    local root = baseUrl(owner, repo, branch)

    local manifestBody, manifestError =
        requestBody(root .. manifestPath, timeout)

    if not manifestBody then
        return false, "Manifest: " .. tostring(manifestError)
    end

    local manifest, parseError = parseManifest(manifestBody)

    if not manifest then
        return false, "Manifest invalid: " .. tostring(parseError)
    end

    local staged = {}

    -- Phase 1: download and validate every file before changing the installation.
    for _, file in ipairs(manifest.files) do
        if type(file.remote) ~= "string" or type(file.localPath) ~= "string" then
            cleanupTemps(staged)
            return false, "Malformed manifest entry"
        end

        local body, downloadError =
            requestBody(root .. file.remote, timeout)

        if not body then
            cleanupTemps(staged)
            return false, ("%s: %s"):format(file.remote, tostring(downloadError))
        end

        local valid, validationError =
            validateLua(file.remote, body)

        if not valid then
            cleanupTemps(staged)
            return false, ("%s invalid: %s"):format(file.remote, tostring(validationError))
        end

        ensureParent(file.localPath)

        local tempPath = file.localPath .. ".new"
        local backupPath = file.localPath .. ".bak"

        if fs.exists(tempPath) then
            fs.delete(tempPath)
        end

        local handle = fs.open(tempPath, "w")

        if not handle then
            cleanupTemps(staged)
            return false, "Cannot write " .. tempPath
        end

        handle.write(body)
        handle.close()

        table.insert(staged, {
            localPath = file.localPath,
            tempPath = tempPath,
            backupPath = backupPath,
            didNotExistBefore = not fs.exists(file.localPath),
        })
    end

    -- Phase 2: back up the complete current installation.
    for _, entry in ipairs(staged) do
        if fs.exists(entry.backupPath) then
            fs.delete(entry.backupPath)
        end

        if fs.exists(entry.localPath) then
            local ok, backupError =
                pcall(fs.copy, entry.localPath, entry.backupPath)

            if not ok then
                rollback(staged)
                return false, ("Backup %s: %s"):format(
                    entry.localPath,
                    tostring(backupError)
                )
            end
        end
    end

    -- Phase 3: replace every file.
    for _, entry in ipairs(staged) do
        local ok, replaceError = pcall(function()
            if fs.exists(entry.localPath) then
                fs.delete(entry.localPath)
            end

            fs.move(entry.tempPath, entry.localPath)
        end)

        if not ok then
            rollback(staged)
            return false, ("Replace %s: %s"):format(
                entry.localPath,
                tostring(replaceError)
            )
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
