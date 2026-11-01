local M={}

local function clamp(value)
    if type(value)~="number" then return nil end
    return math.max(0,math.min(1,value))
end

function M.fromLegacy(packet)
    if type(packet)~="table"
        or packet.contract~=1
        or packet.id~="biofuel" then
        return nil,"expected legacy biofuel contract v1 packet"
    end

    local ui=type(packet.ui)=="table" and packet.ui or {}
    local inputFill=clamp(ui.inputFill)
    local outputFill=clamp(ui.outputFill)
    local energyFill=clamp(ui.energyFill)

    return {
        contract=2,
        id="biofuel",
        label=packet.label or "BIOFUEL",
        category=packet.type or "process",
        version=packet.version,

        runtime=packet.runtimeState or "UNKNOWN",
        mode=packet.mode or "UNKNOWN",
        state=packet.state or "UNKNOWN",
        health=packet.health or "UNKNOWN",
        reason=packet.reason or "-",

        metrics={
            potato=inputFill,
            biofuel=outputFill,
            energy=energyFill,
        },

        resources={
            potato={
                fill=inputFill,
                count=ui.inputCount,
                item=ui.inputItem,
            },
            biofuel={
                fill=outputFill,
                count=ui.outputCount,
                item="mekanism:bio_fuel",
            },
        },

        chains={
            biofuel={
                enabled=true,
                state=ui.crusherState or packet.state or "UNKNOWN",
                reason=packet.reason,
            },
        },

        machines={
            crusher={
                peripheral=ui.crusherName,
                kind="CRUSHER",
                state=ui.crusherState or "UNKNOWN",
                energy=ui.energy,
                maxEnergy=ui.maxEnergy,
                energyUsage=ui.energyUsage,
                controllable=true,
            },
        },

        module={
            inputCount=ui.inputCount,
            inputCapacity=ui.inputCapacity,
            outputCount=ui.outputCount,
            outputCapacity=ui.outputCapacity,
            targetItems=ui.targetItems,
            resumeItems=ui.resumeItems,
            autoConfigured=ui.autoConfigured,
        },

        alarms=packet.alarms or {},
        legacy={contract=1,packet=packet},
    }
end

return M
