return {
    version = "0.7.6",

    -- Program files and startup are updated automatically.
    -- Runtime configuration remains preserved.
    files = {
        {
            remote = "programs/factory/h2o2.lua",
            localPath = "/programs/factory/h2o2.lua",
        },
        {
            remote = "programs/factory/peripheral_probe.lua",
            localPath = "/programs/factory/peripheral_probe.lua",
        },
        {
            remote = "programs/factory/lib/updater.lua",
            localPath = "/programs/factory/lib/updater.lua",
        },
        {
            remote = "programs/factory/lib/status_bus.lua",
            localPath = "/programs/factory/lib/status_bus.lua",
        },
        {
            remote = "programs/factory/update_manifest.lua",
            localPath = "/programs/factory/update_manifest.lua",
        },
        {
            remote = "startup_factory.lua",
            localPath = "/startup.lua",
        },
    },
}
