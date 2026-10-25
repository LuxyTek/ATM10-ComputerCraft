return {
    -- Rafraichissement des donnees rapides.
    refreshSeconds = 1,

    -- ME Bridge : metriques rapides / donnees lourdes.
    meRefreshSeconds = 5,
    meHeavyRefreshSeconds = 30,

    -- Redecouverte des peripheriques CC:Tweaked.
    peripheralRefreshSeconds = 10,

    textScale = 0.5,

    -- nil = utilise le premier monitor detecte.
    -- Exemple : "monitor_0"
    monitor = nil,

    -- Laisse vide pour detecter automatiquement tous les stockages d'energie.
    -- Si d'autres machines energetiques sont visibles sur le reseau CC,
    -- renseigne ici uniquement les Energy Cubes a compter.
    devices = {
        -- "mekanism:energy_cube_0",
        -- "mekanism:energy_cube_1",
    },

    showDevices = true,

    -- Seuils de la supervision energetique.
    lowThreshold = 0.25,
    warningThreshold = 0.60,

    -- Fenetre de lissage pour charge/decharge et estimation.
    trendSeconds = 30,
}
