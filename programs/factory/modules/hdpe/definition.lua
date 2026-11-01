return {
    contract=2,
    id="hdpe",
    label="HDPE",
    category="process",

    inputs={
        { id="substrate", label="SUBSTRATE" },
        { id="liquid_ethene", label="LIQ ETHENE" },
        { id="oxygen", label="OXYGEN" },
    },

    outputs={
        { id="hdpe_pellet", label="HDPE PELLET" },
    },

    chains={
        {
            id="hdpe",
            label="HDPE",
            controllable=true,
            machines={"prc"},
            inputs={"substrate","liquid_ethene","oxygen"},
            outputs={"hdpe_pellet"},
        },
    },

    machines={
        {
            id="prc",
            label="PRC",
            chain="hdpe",
        },
    },

    actions={
        ["module.set_mode"]=true,
        ["module.start_all"]=true,
        ["module.stop_all"]=true,
        ["chain.start"]=true,
        ["chain.stop"]=true,
        ["machine.start"]=true,
        ["machine.stop"]=true,
    },
}
