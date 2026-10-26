return {
    refreshSeconds = 1,
    textScale = 0.5,
    monitor = nil,
    stopMode = "HIGH", -- STOP logiciel, sans signal redstone externe sur les machines.

    lines = {
        { id = "LINE 1", pump = "electricPump_2", separator = "electrolyticSeparator_2" },
        { id = "LINE 2", pump = "electricPump_1", separator = "electrolyticSeparator_0" },
        { id = "LINE 3", pump = "electricPump_0", separator = "electrolyticSeparator_1" },
    },


    status = {
        publishSeconds = 2,
        id = "h2o2",
        label = "H2/O2",
        type = "process",
    },

    auto = {
        checkSeconds = 2,

        -- Securite eau : arret sous 10 %, reprise seulement au-dessus de 40 %.
        waterStop = 0.10,
        waterResume = 0.40,

        -- Les Quantum Entangloporters H2/O2 peuvent contenir du gaz hors supervision.
        -- Les Chemical Tanks locaux restent donc la reserve de reference.
        -- Le tank local le moins rempli pilote la demande.
        chemicalStop = 0.95,
        chemicalResume = 0.80,

        -- Regulation progressive des 3 lignes.
        scaleToTwo = 0.30,
        scaleToOne = 0.70,
        stageHysteresis = 0.05,

        -- Anti-blocage Separator : si un gaz local est quasi plein
        -- alors que l'autre doit encore etre produit, sa sortie passe
        -- temporairement en DUMPING complet pour vider le buffer interne
        -- assez vite et eviter tout blocage du Separator.
        overflowEnable = 0.98,
        overflowDisable = 0.90,
    },


    -- Les noms reels seront renseignes apres peripheral_probe.lua.
    devices = {
        separator = nil,
        waterTank = nil,
        hydrogenTank = nil,
        oxygenTank = nil,
        energyCube = nil,
        monitor = nil,
        pump = nil,
    },

    mode = "BALANCED",
}
