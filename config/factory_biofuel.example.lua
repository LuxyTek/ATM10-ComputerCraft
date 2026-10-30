return {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,

    -- Mapping confirme sur le prototype BIOFUEL.
    inputBarrel = "sophisticatedstorage:barrel_0",
    crusher = "ultimateCrushingFactory_0",
    outputBarrel = "sophisticatedstorage:barrel_1",
    stopMode = "HIGH",

    auto = {
        -- A renseigner avec la capacite/stock cible reel du barrel.
        targetItems = nil,
        -- nil = 80 % de targetItems.
        resumeItems = nil,
        checkSeconds = 2,
    },

    status = {
        publishSeconds = 2,
        id = "biofuel",
        label = "BIOFUEL",
        type = "process",
    },
}
