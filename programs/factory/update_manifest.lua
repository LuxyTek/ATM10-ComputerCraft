return {
    version = "0.1.0-dev",

    -- Only program files are updated automatically.
    -- Runtime configuration is deliberately preserved.
    files = {
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
