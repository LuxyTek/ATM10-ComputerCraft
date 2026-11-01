return {
    -- Physical mapping currently validated in the factory.
    -- Logical V2 IDs stay stable even if these peripheral names change.
    lines = {
        {
            id = "LINE 1",
            pump = "electricPump_2",
            separator = "electrolyticSeparator_2",
        },
        {
            id = "LINE 2",
            pump = "electricPump_1",
            separator = "electrolyticSeparator_0",
        },
        {
            id = "LINE 3",
            pump = "electricPump_0",
            separator = "electrolyticSeparator_1",
        },
    },

    stopMode = "HIGH",

    auto = {
        waterStop = 0.10,
        waterResume = 0.40,
        chemicalStop = 0.95,
        chemicalResume = 0.80,
        scaleToTwo = 0.30,
        scaleToOne = 0.70,
        stageHysteresis = 0.05,
        overflowEnable = 0.80,
        overflowDisable = 0.20,
    },

    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },
}
