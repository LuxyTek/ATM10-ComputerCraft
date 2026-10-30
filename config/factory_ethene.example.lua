return {
    stopMode = "HIGH",

    biofuelBarrel = "sophisticatedstorage:barrel_1",
    biofuelCapacity = 270336,
    etheneTank = "ultimateMaxChemicalTank_2",
    condensentrator = "rotaryCondensentrator_0",
    liquidEtheneTank = "ultimateFluidTank_7",

    lines = {
        {
            id = "LINE 1",
            waterTank = "ultimateFluidTank_5",
            pump = "electricPump_4",
            prc = "pressurizedReactionChamber_2",
        },
        {
            id = "LINE 2",
            waterTank = "ultimateFluidTank_6",
            pump = "electricPump_3",
            prc = "pressurizedReactionChamber_3",
        },
    },

    auto = {
        etheneStop = 0.95,
        etheneResume = 0.80,
        scaleToTwo = 0.30,

        liquidStop = 0.95,
        liquidResume = 0.80,

        waterStop = 0.10,
        waterResume = 0.40,

        hydrogenStop = 0.10,
        hydrogenResume = 0.20,

        substrateWarn = 48,
        substrateStop = 64,
    },

    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },

    status = {
        publishSeconds = 2,
        id = "ethene",
        label = "ETHENE",
        type = "process",
    },
}
