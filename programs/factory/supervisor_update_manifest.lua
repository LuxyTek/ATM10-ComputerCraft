return {
    version = "0.1.0",

    files = {
        {
            remote = "programs/factory/supervisor.lua",
            localPath = "/programs/factory/supervisor.lua",
        },
        {
            remote = "programs/factory/lib/updater.lua",
            localPath = "/programs/factory/lib/updater.lua",
        },
        {
            remote = "programs/factory/supervisor_update_manifest.lua",
            localPath = "/programs/factory/supervisor_update_manifest.lua",
        },
        {
            remote = "startup_factory_supervisor.lua",
            localPath = "/startup.lua",
        },
    },
}
