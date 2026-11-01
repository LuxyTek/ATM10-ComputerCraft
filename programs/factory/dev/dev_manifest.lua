return {
    version = "0.4.1-dev",

    files = {
        { remote="programs/factory/core/contract.lua", localPath="/programs/factory/core/contract.lua" },
        { remote="programs/factory/core/loader.lua", localPath="/programs/factory/core/loader.lua" },
        { remote="programs/factory/core/registry.lua", localPath="/programs/factory/core/registry.lua" },
        { remote="programs/factory/core/status_adapter.lua", localPath="/programs/factory/core/status_adapter.lua" },
        { remote="programs/factory/core/bus.lua", localPath="/programs/factory/core/bus.lua" },

        { remote="programs/factory/ui/widgets.lua", localPath="/programs/factory/ui/widgets.lua" },
        { remote="programs/factory/ui/overview.lua", localPath="/programs/factory/ui/overview.lua" },
        { remote="programs/factory/ui/machines.lua", localPath="/programs/factory/ui/machines.lua" },
        { remote="programs/factory/ui/flow_map.lua", localPath="/programs/factory/ui/flow_map.lua" },

        { remote="programs/factory/modules/h2o2/definition.lua", localPath="/programs/factory/modules/h2o2/definition.lua" },
        { remote="programs/factory/modules/h2o2/legacy_adapter.lua", localPath="/programs/factory/modules/h2o2/legacy_adapter.lua" },
        { remote="programs/factory/modules/h2o2/control_adapter.lua", localPath="/programs/factory/modules/h2o2/control_adapter.lua" },
        { remote="programs/factory/modules/h2o2/config.example.lua", localPath="/programs/factory/modules/h2o2/config.example.lua" },

        { remote="programs/factory/tools/core_v2_smoke_test.lua", localPath="/programs/factory/tools/core_v2_smoke_test.lua" },
        { remote="programs/factory/tools/ui_v2_smoke_test.lua", localPath="/programs/factory/tools/ui_v2_smoke_test.lua" },
        { remote="programs/factory/tools/h2o2_v2_smoke_test.lua", localPath="/programs/factory/tools/h2o2_v2_smoke_test.lua" },
        { remote="programs/factory/tools/h2o2_v2_live_test.lua", localPath="/programs/factory/tools/h2o2_v2_live_test.lua" },
        { remote="programs/factory/tools/h2o2_v2_control.lua", localPath="/programs/factory/tools/h2o2_v2_control.lua" },

        { remote="programs/factory/dev/dev_updater.lua", localPath="/programs/factory/dev/dev_updater.lua" },
        { remote="programs/factory/dev/dev_manifest.lua", localPath="/programs/factory/dev/dev_manifest.lua" },
        { remote="programs/factory/dev/dev_panel.lua", localPath="/programs/factory/dev/dev_panel.lua" },
        { remote="startup_factory_v2_dev.lua", localPath="/startup_factory_v2_dev.lua" },
    },
}
