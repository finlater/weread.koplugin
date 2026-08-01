-- This file is copied into KOReader's spec/front/unit tree by
-- scripts/run_koreader_integration.sh and runs with KOReader's own Busted setup.

describe("WeRead plugin integration", function()
    setup(function()
        require("commonrequire")
        disable_plugins()
    end)

    it("is discovered and loaded by KOReader PluginLoader", function()
        load_plugin("weread.koplugin")

        local PluginLoader = require("pluginloader")
        local plugin
        for _, candidate in ipairs(PluginLoader.enabled_plugins) do
            if candidate.name == "weread" then
                plugin = candidate
                break
            end
        end

        assert.is_table(plugin)
        assert.equals("weread", plugin.name)
        assert.equals("WeRead", plugin.fullname)
        assert.is_false(plugin.is_doc_only)
        assert.matches("weread%.koplugin$", plugin.path)
    end)

    it("loads project modules only through the weread namespace", function()
        assert.is_table(package.loaded["weread.lib.client"])
        assert.is_table(package.loaded["weread.lib.settings"])
        assert.is_table(package.loaded["weread.ui.menu"])
        assert.is_nil(package.loaded["lib.client"])
        assert.is_nil(package.loaded["lib.settings"])
        assert.is_nil(package.loaded["ui.menu"])
    end)
end)
