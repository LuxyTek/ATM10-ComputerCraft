return {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,

    -- Mapping confirme sur le prototype BIOFUEL.
    inputBarrel = "sophisticatedstorage:barrel_0",
    crusher = "ultimateCrushingFactory_0",
    outputBarrel = "sophisticatedstorage:barrel_1",
    inputCapacity = 270336,
    outputCapacity = 270336,
    stopMode = "HIGH",

    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },

    auto = {
        -- A renseigner avec la capacite/stock cible reel du barrel.
        targetItems = 270336,
        -- nil = 80 % de targetItems.
        resumeItems = 216269,
        checkSeconds = 2,
    },

    status = {
        publishSeconds = 2,
        id = "biofuel",
        label = "BIOFUEL",
        type = "process",
    },
}
