return {
    version = "0.1.0",

    -- Runtime configuration is preserved.
    files = {
        {
            remote = "programs/factory/biofuel.lua",
            localPath = "/programs/factory/biofuel.lua",
        },
        {
            remote = "programs/factory/lib/updater.lua",
            localPath = "/programs/factory/lib/updater.lua",
        },
        {
            remote = "programs/factory/biofuel_update_manifest.lua",
            localPath = "/programs/factory/biofuel_update_manifest.lua",
        },
        {
            remote = "startup_factory_biofuel.lua",
            localPath = "/startup.lua",
        },
    },
}
