return {
    stopMode = "HIGH",

    prc = "pressurizedReactionChamber_4",
    outputBarrel = "sophisticatedstorage:barrel_3",
    outputCapacity = 270336,

    auto = {
        outputStop = 0.95,
        outputResume = 0.80,
    },

    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },

    status = {
        publishSeconds = 2,
        id = "hdpe",
        label = "HDPE",
        type = "process",
    },
}
