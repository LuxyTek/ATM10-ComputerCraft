return {
    title = "MEKANISM POWER",
    refreshSeconds = 1,
    textScale = 0.5,

    -- nil = utilise le premier monitor detecte.
    -- Exemple : "monitor_0"
    monitor = nil,

    -- Laisse vide pour detecter automatiquement tous les peripheriques
    -- compatibles avec le type generique "energy_storage".
    -- Si tu relies plus tard d'autres machines au meme reseau CC,
    -- renseigne ici uniquement les Energy Cubes a compter.
    devices = {
        -- "mekanism:energy_cube_0",
        -- "mekanism:energy_cube_1",
    },

    showDevices = true,
    lowThreshold = 0.25,
    warningThreshold = 0.60,
}
