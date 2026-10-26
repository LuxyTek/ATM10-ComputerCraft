return {
    version = "0.2.0",

    -- Only program files are updated automatically.
    -- Runtime configuration is deliberately preserved.
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
            remote = "programs/factory/update_manifest.lua",
            localPath = "/programs/factory/update_manifest.lua",
        },
    },
}
