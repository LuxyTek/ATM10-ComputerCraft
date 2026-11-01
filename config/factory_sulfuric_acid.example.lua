return {
    stopMode = "HIGH",
    sulfurDioxideTank = "ultimateMaxChemicalTank_3",
    waterVaporTank = "ultimateMaxChemicalTank_4",
    sulfurTrioxideTank = "ultimateMaxChemicalTank_5",
    sulfuricAcidTank = "ultimateMaxChemicalTank_6",
    oxidizers = {
        "chemicalOxidizer_0",
        "chemicalOxidizer_1",
    },
    sulfurTrioxideInfuser = "chemicalInfuser_1",
    sulfuricAcidInfuser = "chemicalInfuser_2",
    auto = {
        outputStop = 0.95,
        outputResume = 0.80,
        inputStop = 0.10,
        inputResume = 0.20,
    },
    runtime = {
        activeSeconds = 1,
        idleSeconds = 15,
        sleepSeconds = 600,
    },
    status = {
        publishSeconds = 2,
        id = "sulfuric",
        label = "SULFURIC ACID",
        type = "process",
    },
}
