-- Focused tests for the prefetch submenu and KOReader dispatcher action.

package.path = "./?.lua;" .. package.path

local registered = {}
local shown_widget
package.preload["dispatcher"] = function()
    return {
        registerAction = function(_self, name, action)
            registered[name] = action
        end,
    }
end
package.preload["ui/bidi"] = function()
    return { dirpath = function(path) return path end }
end
for _, name in ipairs({
    "ui/widget/buttondialog",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
}) do
    package.preload[name] = function()
        return { new = function(_self, options) return options end }
    end
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, widget) shown_widget = widget end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end }
end
package.preload["weread.ui.thought_popup"] = function()
    return { closeVisible = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
    }
end

local Menu = require("weread.ui.menu")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local cache = {
    auto_prefetch_next_chapter = false,
    download_underlines_and_thoughts = false,
    show_prefetch_notifications = true,
}
local host = {
    ui = {},
    version = "test",
    settings = {
        get = function(_self, key, default)
            if key == "cache" then return cache end
            return default
        end,
        set = function() end,
        flush = function() end,
    },
    downloader = { cancelPrefetch = function() end },
    safeCallback = function(_self, _label, callback) return callback end,
}
for key, value in pairs(Menu) do host[key] = value end

host:onDispatcherRegisterActions()
expect(registered.weread_show == nil,
    "generic WeRead shortcut action is no longer registered")
local sync_action = registered.weread_sync_progress
expect(sync_action and sync_action.event == "WeReadSyncProgress"
        and sync_action.title == "WeRead · Sync reading progress"
        and sync_action.reader == true,
    "standalone sync action remains available in reader context")
local quick_action = registered.weread_quick_menu
expect(quick_action ~= nil, "quick menu dispatcher action is registered")
expect(quick_action and quick_action.event == "ShowWeReadQuickMenu",
    "quick menu action dispatches the matching reader event")
expect(quick_action and quick_action.reader == true
        and quick_action.general ~= true,
    "quick menu action remains reader-only")
expect(quick_action and quick_action.title == "WeRead · Quick menu",
    "quick menu action has the requested title")
local bookshelf_action = registered.weread_bookshelf
expect(bookshelf_action and bookshelf_action.event == "ShowWeReadBookshelf",
    "bookshelf dispatcher action uses the matching event")
expect(bookshelf_action and bookshelf_action.general == true
        and bookshelf_action.reader ~= true,
    "bookshelf action is grouped with the general WeRead actions")
expect(bookshelf_action and bookshelf_action.title == "WeRead · Bookshelf",
    "bookshelf gesture action has the requested title")
local general_actions = {
    weread_reading_statistics = {
        event = "ShowWeReadReadingStatistics",
        title = "WeRead · Reading statistics",
    },
    weread_search = {
        event = "ShowWeReadSearch",
        title = "WeRead · Search",
    },
}
expect(registered.weread_local_bookshelf == nil,
    "fork does not expose the skipped upstream local-bookshelf action")
for name, expected in pairs(general_actions) do
    local action = registered[name]
    expect(action and action.event == expected.event
            and action.title == expected.title
            and action.general == true
            and action.reader ~= true,
        name .. " is registered as a prefixed general action")
end

local settings_items = host:getSettingsMenuItems()
local download_settings
local cache_management
for _, item in ipairs(settings_items) do
    if item.text == "Download settings" then download_settings = item end
    if item.text == "Cache management" then cache_management = item end
end
local cache_items = cache_management and cache_management.sub_item_table_func() or {}
expect(cache_items[1] and cache_items[1].keep_menu_open == true
        and cache_items[2] and cache_items[2].keep_menu_open == true,
    "cache dialogs keep the settings menu open")
local main_items = host:getMainMenuItems()
for _, item in ipairs(main_items) do
    if item.text == "Search" or item.text == "Reading statistics" then
        expect(item.keep_menu_open == true,
            item.text .. " keeps the main menu open while its dialog is shown")
    end
end
local download_items = download_settings and download_settings.sub_item_table_func()
local prefetch
for _, item in ipairs(download_items or {}) do
    if item.text == "Chapter prefetch" then prefetch = item end
end
expect(prefetch ~= nil, "download settings contain a prefetch submenu")

local prefetch_items = prefetch and prefetch.sub_item_table_func() or {}
expect(#prefetch_items == 3, "prefetch submenu contains exactly three settings")
expect(prefetch_items[1] and prefetch_items[1].text
        == "Automatically prefetch next chapter",
    "automatic prefetch is the parent switch")
expect(prefetch_items[2] and not prefetch_items[2].enabled_func(),
    "annotation setting is disabled while automatic prefetch is off")
expect(prefetch_items[3] and not prefetch_items[3].enabled_func(),
    "notification setting is disabled while automatic prefetch is off")

local menu_updates = 0
prefetch_items[1].callback({
    updateItems = function() menu_updates = menu_updates + 1 end,
})
expect(cache.auto_prefetch_next_chapter == false and shown_widget ~= nil,
    "enabling automatic prefetch first shows a confirmation")
expect(shown_widget.text:find("few seconds of delay", 1, true) ~= nil,
    "confirmation warns about possible chapter-opening delay")
shown_widget.ok_callback()
expect(cache.auto_prefetch_next_chapter == true and menu_updates == 1,
    "automatic prefetch is enabled only after confirmation")

expect(prefetch_items[2].enabled_func(),
    "annotation setting is enabled while automatic prefetch is on")
expect(prefetch_items[3].enabled_func(),
    "notification setting is enabled while automatic prefetch is on")

print(string.format(
    "menu_prefetch_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
