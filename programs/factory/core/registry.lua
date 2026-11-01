local CONTRACT_PATH = "/programs/factory/core/contract.lua"
local LOADER_PATH = "/programs/factory/core/loader.lua"

local contract = dofile(CONTRACT_PATH)
local loader = dofile(LOADER_PATH)

local Registry = {}
Registry.__index = Registry

local function copyArray(source)
    local result = {}
    for _, value in ipairs(source or {}) do table.insert(result, value) end
    return result
end

function Registry.new(options)
    options = options or {}

    return setmetatable({
        root = options.root or "/programs/factory/modules",
        modules = {},
        order = {},
        errors = {},
    }, Registry)
end

function Registry:clear()
    self.modules = {}
    self.order = {}
    self.errors = {}
end

function Registry:add(definition, sourcePath)
    local valid, validationError = contract.validateDefinition(definition)
    if not valid then
        return false, validationError
    end

    if self.modules[definition.id] ~= nil then
        return false, "duplicate module id: " .. definition.id
    end

    local normalized = contract.withDefaults(definition)
    normalized._source = sourcePath

    self.modules[normalized.id] = normalized
    table.insert(self.order, normalized.id)
    table.sort(self.order)

    return true
end

function Registry:load()
    self:clear()

    local files, listError = loader.listDefinitionFiles(self.root)
    if not files then
        table.insert(self.errors, {
            path = self.root,
            error = listError,
        })
        return false, self.errors
    end

    for _, path in ipairs(files) do
        local definition, loadError = loader.loadTable(path)
        if not definition then
            table.insert(self.errors, { path=path, error=loadError })
        else
            local ok, addError = self:add(definition, path)
            if not ok then
                table.insert(self.errors, { path=path, error=addError })
            end
        end
    end

    return #self.errors == 0, self.errors
end

function Registry:get(id)
    return self.modules[id]
end

function Registry:list()
    local result = {}
    for _, id in ipairs(self.order) do
        table.insert(result, self.modules[id])
    end
    return result
end

function Registry:ids()
    return copyArray(self.order)
end

local function hasResource(items, resourceId)
    for _, resource in ipairs(items or {}) do
        if resource.id == resourceId then return true end
    end
    return false
end

function Registry:producers(resourceId)
    local result = {}
    for _, module in ipairs(self:list()) do
        if hasResource(module.outputs, resourceId) then
            table.insert(result, module)
        end
    end
    return result
end

function Registry:consumers(resourceId)
    local result = {}
    for _, module in ipairs(self:list()) do
        if hasResource(module.inputs, resourceId) then
            table.insert(result, module)
        end
    end
    return result
end

function Registry:resources()
    local seen = {}
    local result = {}

    for _, module in ipairs(self:list()) do
        for _, collection in ipairs({ module.inputs, module.outputs }) do
            for _, resource in ipairs(collection or {}) do
                if not seen[resource.id] then
                    seen[resource.id] = true
                    table.insert(result, resource.id)
                end
            end
        end
    end

    table.sort(result)
    return result
end

function Registry:topology()
    local edges = {}

    for _, resourceId in ipairs(self:resources()) do
        local producers = self:producers(resourceId)
        local consumers = self:consumers(resourceId)

        for _, producer in ipairs(producers) do
            for _, consumer in ipairs(consumers) do
                if producer.id ~= consumer.id then
                    table.insert(edges, {
                        resource = resourceId,
                        from = producer.id,
                        to = consumer.id,
                    })
                end
            end
        end
    end

    table.sort(edges, function(a, b)
        if a.from ~= b.from then return a.from < b.from end
        if a.to ~= b.to then return a.to < b.to end
        return a.resource < b.resource
    end)

    return edges
end

return Registry
