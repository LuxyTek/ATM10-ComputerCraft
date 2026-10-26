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


    auto = {
        checkSeconds = 2,

        -- Securite eau : arret sous 10 %, reprise seulement au-dessus de 40 %.
        waterStop = 0.10,
        waterResume = 0.40,

        -- Le buffer le plus rempli entre H2 et O2 pilote la production.
        chemicalStop = 0.95,
        chemicalResume = 0.80,

        -- Regulation progressive des 3 lignes.
        scaleToTwo = 0.30,
        scaleToOne = 0.70,
        stageHysteresis = 0.05,
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
