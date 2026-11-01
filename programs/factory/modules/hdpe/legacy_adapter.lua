local M={}

local function clamp(value)
    if type(value)~="number" then return nil end
    return math.max(0,math.min(1,value))
end

function M.fromLegacy(packet)
    if type(packet)~="table"
        or packet.contract~=1
        or packet.id~="hdpe" then
        return nil,"expected legacy hdpe contract v1 packet"
    end

    local ui=type(packet.ui)=="table" and packet.ui or {}
    local hdpe=clamp(ui.outputFill or (packet.metrics and packet.metrics.hdpe))
    local liquid=clamp(ui.liquidEtheneFill or (packet.metrics and packet.metrics.liquidEthene))
    local oxygen=clamp(ui.oxygenFill or (packet.metrics and packet.metrics.oxygen))

    local substrateCount=ui.substrateCount
        or (packet.metrics and packet.metrics.substrateCount)

    return {
        contract=2,
        id="hdpe",
        label=packet.label or "HDPE",
        category=packet.type or "process",
        version=packet.version,

        runtime=packet.runtimeState or "UNKNOWN",
        mode=packet.mode or "UNKNOWN",
        state=packet.state or "UNKNOWN",
        health=packet.health or "UNKNOWN",
        reason=packet.reason or "-",

        metrics={
            substrate=substrateCount,
            liquid_ethene=liquid,
            oxygen=oxygen,
            hdpe_pellet=hdpe,
        },

        resources={
            substrate={
                count=substrateCount,
                item=ui.substrateName or "mekanism:substrate",
            },
            liquid_ethene={fill=liquid},
            oxygen={fill=oxygen},
            hdpe_pellet={
                fill=hdpe,
                count=ui.outputCount,
                item=ui.outputItem,
            },
        },

        chains={
            hdpe={
                enabled=true,
                state=ui.prcState or packet.state or "UNKNOWN",
                reason=packet.reason,
            },
        },

        machines={
            prc={
                peripheral=ui.prcName,
                kind="PRC",
                state=ui.prcState or "UNKNOWN",
                substrateCount=ui.substratePrcReserve,
                liquidEtheneFill=liquid,
                oxygenFill=oxygen,
                energy=ui.energy,
                maxEnergy=ui.maxEnergy,
                energyUsage=ui.energyUsage,
                controllable=true,
            },
        },

        module={
            outputCount=ui.outputCount,
            outputCapacity=ui.outputCapacity,
            outputStop=ui.outputStop,
            outputResume=ui.outputResume,
            substrateBuffer=ui.substrateBarrel,
        },

        alarms=packet.alarms or {},
        legacy={contract=1,packet=packet},
    }
end

return M
