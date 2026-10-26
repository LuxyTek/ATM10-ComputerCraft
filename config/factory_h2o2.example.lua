return {
    refreshSeconds = 1,

    thresholds = {
        waterStop = 0.10,
        waterResume = 0.40,

        energyStop = 0.15,
        energyResume = 0.30,

        chemicalStop = 0.95,
        chemicalResume = 0.80,
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
