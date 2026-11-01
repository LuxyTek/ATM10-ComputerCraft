return {
    contract = 2,

    id = "h2o2",
    label = "H2/O2",
    category = "process",

    inputs = {
        {
            id = "water",
            label = "WATER",
        },
    },

    outputs = {
        {
            id = "hydrogen",
            label = "HYDROGEN",
        },
        {
            id = "oxygen",
            label = "OXYGEN",
        },
    },

    chains = {
        {
            id = "line_1",
            label = "LINE 1",
            controllable = true,
            machines = {
                "line_1_pump",
                "line_1_separator",
            },
            inputs = { "water" },
            outputs = { "hydrogen", "oxygen" },
        },
        {
            id = "line_2",
            label = "LINE 2",
            controllable = true,
            machines = {
                "line_2_pump",
                "line_2_separator",
            },
            inputs = { "water" },
            outputs = { "hydrogen", "oxygen" },
        },
        {
            id = "line_3",
            label = "LINE 3",
            controllable = true,
            machines = {
                "line_3_pump",
                "line_3_separator",
            },
            inputs = { "water" },
            outputs = { "hydrogen", "oxygen" },
        },
    },

    machines = {
        {
            id = "line_1_pump",
            label = "PUMP",
            chain = "line_1",
        },
        {
            id = "line_1_separator",
            label = "SEPARATOR",
            chain = "line_1",
        },
        {
            id = "line_2_pump",
            label = "PUMP",
            chain = "line_2",
        },
        {
            id = "line_2_separator",
            label = "SEPARATOR",
            chain = "line_2",
        },
        {
            id = "line_3_pump",
            label = "PUMP",
            chain = "line_3",
        },
        {
            id = "line_3_separator",
            label = "SEPARATOR",
            chain = "line_3",
        },
    },

    actions = {
        ["module.set_mode"] = true,
        ["module.start_all"] = true,
        ["module.stop_all"] = true,

        -- Physical line control in MANUAL.
        -- Unlike chain.set_enabled, these are not persistent AUTO permissions.
        ["chain.start"] = true,
        ["chain.stop"] = true,

        ["machine.start"] = true,
        ["machine.stop"] = true,
    },
}
