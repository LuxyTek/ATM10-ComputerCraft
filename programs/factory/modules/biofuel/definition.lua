return {
    contract=2,
    id="biofuel",
    label="BIOFUEL",
    category="process",

    inputs={
        { id="potato", label="POTATO" },
    },

    outputs={
        { id="biofuel", label="BIOFUEL" },
    },

    chains={
        {
            id="biofuel",
            label="BIOFUEL",
            controllable=true,
            machines={"crusher"},
            inputs={"potato"},
            outputs={"biofuel"},
        },
    },

    machines={
        {
            id="crusher",
            label="CRUSHER",
            chain="biofuel",
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
