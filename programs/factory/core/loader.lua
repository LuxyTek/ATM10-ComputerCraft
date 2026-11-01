local M = {}

function M.loadTable(path)
    if type(path) ~= "string" or path == "" then
        return nil, "path is required"
    end
    if not fs.exists(path) then
        return nil, "file not found: " .. path
    end
    if fs.isDir(path) then
        return nil, "path is a directory: " .. path
    end

    local chunk, loadError = loadfile(path)
    if not chunk then
        return nil, "load failed: " .. tostring(loadError)
    end

    local ok, result = pcall(chunk)
    if not ok then
        return nil, "execution failed: " .. tostring(result)
    end
    if type(result) ~= "table" then
        return nil, "file must return a table: " .. path
    end

    return result
end

function M.listDefinitionFiles(root)
    root = root or "/programs/factory/modules"

    if not fs.exists(root) then return {} end
    if not fs.isDir(root) then
        return nil, "module root is not a directory: " .. root
    end

    local result = {}
    for _, entry in ipairs(fs.list(root)) do
        if entry:sub(1, 1) ~= "." and entry:sub(1, 1) ~= "_" then
            local moduleDir = fs.combine(root, entry)
            if fs.isDir(moduleDir) then
                local definitionPath = fs.combine(moduleDir, "definition.lua")
                if fs.exists(definitionPath) and not fs.isDir(definitionPath) then
                    table.insert(result, definitionPath)
                end
            end
        end
    end

    table.sort(result)
    return result
end

return M
