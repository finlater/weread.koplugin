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
package.preload["weread.lib.parallel"] = function()
    return {
        MAX_CONCURRENCY = 8,
        config = function(settings)
            local value = settings:get("cache")
            if value.concurrency_auto == false then
                return {
                    automatic = false,
                    supported = true,
                    memory_mb = 1024,
                    chapters = value.chapter_concurrency,
                    comments = value.comment_concurrency,
                    images = value.image_concurrency,
                }
            end
            return {
                automatic = true,
                supported = true,
                memory_mb = 1024,
                chapters = 2,
                comments = 3,
                images = 3,
            }
        end,
    }
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
    concurrency_auto = true,
    chapter_concurrency = 2,
    comment_concurrency = 2,
    image_concurrency = 2,
}
local available_version
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
    updater = { available_version = function() return available_version end },
    safeCallback = function(_self, _label, callback) return callback end,
}
for key, value in pairs(Menu) do host[key] = value end

host:onDispatcherRegisterActions()
expect(registered.weread_show == nil,
    "generic WeRead shortcut action is no longer registered")
local sync_action = registered.weread_sync_progress
expect(sync_action == nil,
    "standalone sync action is no longer registered")
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
    weread_local_bookshelf = {
        event = "ShowWeReadLocalBookshelf",
        title = "WeRead · Local bookshelf",
    },
    weread_reading_statistics = {
        event = "ShowWeReadReadingStatistics",
        title = "WeRead · Reading statistics",
    },
    weread_search = {
        event = "ShowWeReadSearch",
        title = "WeRead · Search",
    },
}
for name, expected in pairs(general_actions) do
    local action = registered[name]
    expect(action and action.event == expected.event
            and action.title == expected.title
            and action.general == true
            and action.reader ~= true,
        name .. " is registered as a prefixed general action")
end

local settings_items = host:getSettingsMenuItems()
local last_settings_item = settings_items[#settings_items]
expect(last_settings_item and last_settings_item.text == "About",
    "about is the last settings menu item")
local about_items = last_settings_item and last_settings_item.sub_item_table_func()
expect(about_items and #about_items == 5,
    "about contains version, author, and three update settings")
for index, item in ipairs(about_items or {}) do
    expect(item.keep_menu_open == true,
        "about item " .. index .. " keeps the menu open")
end
expect(about_items[1] and about_items[1].text == "Version %1",
    "version is the first about item")
expect(about_items[2] and about_items[2].text == "Author: %1",
    "author is the second about item")
expect(about_items[3] and about_items[3].text == "Check for updates"
        and about_items[4].text == "Automatically check once a day"
        and about_items[5].text == "Prefer proxy for updates",
    "update settings follow version and author at the same level")
available_version = "0.7.0"
local update_available_items = last_settings_item.sub_item_table_func()
expect(#update_available_items == 5
        and update_available_items[3].text == "Update to v%1",
    "available update replaces the check item without adding a sixth item")
available_version = nil
about_items[1].callback()
expect(shown_widget and shown_widget.text:find("Disclaimer", 1, true),
    "version item preserves the previous about dialog behavior")
local main_items = host:getMainMenuItems()
expect(main_items[#main_items] and main_items[#main_items].text == "Settings",
    "about is no longer present in the outer menu")
for _, item in ipairs(main_items) do
    if item.text == "Search" or item.text == "Reading statistics" then
        expect(item.keep_menu_open == true,
            item.text .. " keeps the main menu open while its dialog is shown")
    end
end
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
local download_items = download_settings and download_settings.sub_item_table_func()
local prefetch, concurrency
for _, item in ipairs(download_items or {}) do
    if item.text == "Chapter prefetch" then prefetch = item end
    if item.text_func and item.text_func():find("Concurrent requests", 1, true) then
        concurrency = item
    end
end
expect(prefetch ~= nil, "download settings contain a prefetch submenu")
expect(concurrency ~= nil, "download settings contain a concurrency submenu")

local concurrency_items = concurrency and concurrency.sub_item_table_func() or {}
expect(#concurrency_items == 5,
    "concurrency submenu contains auto, memory, and three manual settings")
expect(concurrency_items[1].checked_func()
        and not concurrency_items[3].enabled_func()
        and concurrency_items[2].text_func():find("Detected memory", 1, true),
    "automatic concurrency state or memory information was wrong")
concurrency_items[1].callback({ updateItems = function() end })
expect(cache.concurrency_auto == false
        and concurrency_items[3].enabled_func(),
    "automatic concurrency could not switch to manual mode")

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
