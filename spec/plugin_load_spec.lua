-- Entry-point smoke test. All KOReader services are replaced with deterministic
-- fakes, while main.lua and the composition helper remain real.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        error(message or ("check " .. checks .. " failed"))
    end
end

local old_namespace_sentinel = {}
for _, module_name in ipairs({
    "lib.client",
    "lib.downloader",
    "lib.settings",
    "ui.common",
    "ui.menu",
}) do
    package.loaded[module_name] = old_namespace_sentinel
end

package.preload["ui/event"] = function()
    return { new = function(_self, name, value) return { name, value } end }
end
package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end
package.preload["ui/uimanager"] = function()
    return {}
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local base = {
        inherited_from_widget_container = function()
            return true
        end,
    }
    function base:extend(fields)
        fields.__index = fields
        return setmetatable(fields, { __index = self })
    end
    return base
end

local settings_values = {
    read_report = {
        enabled = false,
        mode = "manual",
        book_id = "",
        report_on_open = true,
    },
}
local fake_settings = {
    get = function(_self, key, default)
        local value = settings_values[key]
        if value == nil then return default end
        return value
    end,
}

local migrations_ran = false
local dispatcher_registered = false
local menu_registered = false
local bookshelf_opened = false

package.preload["weread.lib.client"] = function()
    return { new = function(_self, settings) return { settings = settings } end }
end
package.preload["weread.lib.downloader"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["weread.lib.settings"] = function()
    return { new = function() return fake_settings end }
end
package.preload["weread.lib.migrations"] = function()
    return {
        run = function(settings, client)
            migrations_ran = settings == fake_settings
                and client.settings == fake_settings
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
    }
end
package.preload["weread.lib.qr_login"] = function()
    return { new = function() return { kind = "qr_login" } end }
end
package.preload["weread.lib.read_report"] = function()
    return {
        new = function(_self, options)
            options.maybe_start = function() end
            return options
        end,
    }
end
package.preload["weread.lib.progress_sync"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["weread.ui.progress_sync_dialog"] = function()
    return {
        show_choice = function() end,
        notify = function() end,
    }
end
package.preload["weread.lib.reader_lifecycle"] = function()
    return {
        inherited_feature = function()
            return "reader_lifecycle"
        end,
    }
end

package.preload["weread.ui.common"] = function()
    return {
        showInfo = function() end,
        showTransientInfo = function() end,
        refreshUI = function() end,
        refreshShelfCacheIndicators = function() end,
        openFile = function() end,
        safeCallback = function(_self, _label, fn) return fn end,
        requireLogin = function() return true end,
        runOnlineTask = function(_self, _label, fn) return fn() end,
        isNetworkConnected = function() return true end,
    }
end
package.preload["weread.ui.menu"] = function()
    return {
        onDispatcherRegisterActions = function()
            dispatcher_registered = true
        end,
    }
end
package.preload["weread.ui.cache"] = function()
    return {}
end
package.preload["weread.ui.read_report"] = function()
    return {}
end
package.preload["weread.ui.library"] = function()
    return {
        ensureChaptersLoaded = function() return {} end,
        showBookshelf = function()
            bookshelf_opened = true
            return true
        end,
    }
end
package.preload["weread.ui.annotations_controller"] = function()
    return {}
end
package.preload["weread.ui.reader_navigation"] = function()
    return {
        detectWeReadBook = function() return nil end,
        getChapterInfoFromFile = function() return nil end,
        openProgressTargetChapter = function() return false end,
    }
end

local Plugin = dofile("main.lua")
local plugin = setmetatable({
    ui = {
        menu = {
            registerToMainMenu = function(_self, registered_plugin)
                menu_registered = registered_plugin ~= nil
            end,
        },
    },
}, { __index = Plugin })
plugin:init()

expect(plugin.name == "weread", "plugin metadata was not loaded")
expect(plugin:inherited_from_widget_container(),
    "KOReader WidgetContainer inheritance was broken")
expect(plugin:inherited_feature() == "reader_lifecycle",
    "feature mixins were not composed")
expect(plugin.settings == fake_settings, "settings service was not initialized")
expect(plugin.client.settings == fake_settings, "client did not receive settings")
expect(plugin.downloader.settings == fake_settings,
    "downloader did not receive settings")
expect(plugin.qr_login.kind == "qr_login", "QR login service was not initialized")
expect(migrations_ran, "migrations did not run during initialization")
expect(dispatcher_registered, "dispatcher actions were not registered")
expect(menu_registered, "plugin was not registered in KOReader's main menu")
expect(plugin:launch() == true and bookshelf_opened,
    "standard third-party launcher entry did not open the bookshelf")
expect(type(plugin.openBookshelf) == "function",
    "stable bookshelf entry point was not exposed")
expect(package.loaded["weread.lib.client"] ~= nil,
    "namespaced client module was not loaded")
expect(package.loaded["weread.ui.menu"] ~= nil,
    "namespaced menu module was not loaded")

for _, module_name in ipairs({
    "lib.client",
    "lib.downloader",
    "lib.settings",
    "ui.common",
    "ui.menu",
}) do
    expect(package.loaded[module_name] == old_namespace_sentinel,
        "main.lua touched legacy module key " .. module_name)
end

print(("plugin_load_spec: %d checks"):format(checks))
