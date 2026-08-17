-- Main menu and settings menu composition.
local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("weread.lib.logger")
local UIManager = require("ui/uimanager")
local ThoughtPopup = require("weread.ui.thought_popup")
local WeRead = require("weread.lib.protocol")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}

function M:onDispatcherRegisterActions()
    Dispatcher:registerAction("weread_quick_menu", {
        category = "none",
        event = "ShowWeReadQuickMenu",
        title = _("WeRead · Quick menu"),
        reader = true,
    })
    Dispatcher:registerAction("weread_bookshelf", {
        category = "none",
        event = "ShowWeReadBookshelf",
        title = _("WeRead · Bookshelf"),
        general = true,
    })
    Dispatcher:registerAction("weread_local_bookshelf", {
        category = "none",
        event = "ShowWeReadLocalBookshelf",
        title = _("WeRead · Local bookshelf"),
        general = true,
    })
    Dispatcher:registerAction("weread_reading_statistics", {
        category = "none",
        event = "ShowWeReadReadingStatistics",
        title = _("WeRead · Reading statistics"),
        general = true,
    })
    Dispatcher:registerAction("weread_search", {
        category = "none",
        event = "ShowWeReadSearch",
        title = _("WeRead · Search"),
        general = true,
    })
    Dispatcher:registerAction("weread_toggle_annotations", {
        category = "none",
        event = "ToggleWeReadAnnotations",
        title = _("WeRead · Toggle underlines and thoughts"),
        reader = true,
    })
end

function M:addToMainMenu(menu_items)
    menu_items.weread = {
        text = _("WeRead"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function M:getMainMenuItems()
    local items = {
        {
            text_func = function()
                local account = self.settings:get("account", {})
                if account.login_method == "qr" and tonumber(account.login_time or 0) > 0 then
                    local name = type(account.name) == "string" and account.name or ""
                    if name == "" then name = _("Unknown account") end
                    return T(_("Logged in · %1"), name)
                end
                return _("QR code login")
            end,
            keep_menu_open = true,
            callback = self:safeCallback(_("QR login"), function(touchmenu_instance)
                self._login_menu_instance = touchmenu_instance
                local account = self.settings:get("account", {})
                if account.login_method == "qr" and tonumber(account.login_time or 0) > 0 then
                    self:showAccountStatus()
                else
                    self.qr_login:start()
                end
            end),
        },
        {
            text = _("Bookshelf"),
            callback = self:safeCallback(_("Bookshelf"), function()
                self:showBookshelf()
            end),
        },
        {
            text = _("WeRead favorites"),
            callback = self:safeCallback(_("WeRead favorites"), function()
                self:showWereadCollection()
            end),
        },
        {
            text = _("Search"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Search"), function()
                self:showSearch()
            end),
        },
        {
            text = _("Reading time report"),
            sub_item_table_func = function()
                if not self:requireLogin(true, true) then
                    return {}
                end
                return self:getReadReportMenuItems()
            end,
        },
        {
            text = _("Reading statistics"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Reading statistics"), function()
                self:showReadStats()
            end),
        },
        {
            text = _("Settings"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
    }

    if self.ui.document then
        local book_id = self:detectWeReadBook()
        local reader_items = {}
        if book_id ~= nil then
            if not WeRead.is_mp_book(book_id) then
                reader_items[#reader_items + 1] = {
                    text = _("Sync progress now"),
                    keep_menu_open = true,
                    callback = self:safeCallback(_("Sync progress now"), function()
                        self:onWeReadSyncProgress()
                    end),
                }
            end
            reader_items[#reader_items + 1] = {
                text = _("Book details"),
                keep_menu_open = true,
                callback = self:safeCallback(_("Book details"), function()
                    self:showCurrentBookDetails()
                end),
            }
        end
        reader_items[#reader_items + 1] = {
            text = _("Show underlines and thoughts"),
            checked_func = function()
                return self.settings:get("cache").show_annotations ~= false
            end,
            keep_menu_open = true,
            callback = self:safeCallback(_("Show underlines and thoughts"), function()
                self:toggleAnnotationVisibility()
            end),
        }
        if book_id == nil then
            reader_items[#reader_items + 1] = {
                text = _("Local-book underlines and thoughts"),
                enabled_func = function()
                    return self:_xpointerOverlayPrototypeAvailable()
                end,
                sub_item_table_func = function()
                    return self:getXPointerOverlayPrototypeMenuItems()
                end,
            }
        end
        for index = #reader_items, 1, -1 do
            table.insert(items, 2, reader_items[index])
        end
    end

    return items
end

function M:getSettingsMenuItems()
    return {
        {
            text = _("Paginated bookshelf"),
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                return self.settings:get("shelf").paginated ~= false
            end,
            callback = self:safeCallback(_("Paginated bookshelf"),
                function(touchmenu_instance)
                    local shelf = self.settings:get("shelf")
                    shelf.paginated = not (shelf.paginated ~= false)
                    self.settings:set("shelf", shelf)
                    self.settings:flush()
                    self.shelf_view_pages = { books = 1, public_account = 1 }
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end),
        },
        {
            text = _("Cache management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Scan and match local books"),
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Scan and match local books"), function()
                            self:confirmScanLocalCache()
                        end),
                    },
                    {
                        text = _("Cache cleanup"),
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Cache cleanup"), function()
                            self:showCacheManagement()
                        end),
                    },
                    {
                        text_func = function()
                            return T(_("Cache directory: %1"), BD.dirpath(self.settings:get_download_dir()))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Cache directory"), function(touchmenu_instance)
                            self:showDownloadDirPicker(touchmenu_instance)
                        end),
                    },
                }
            end,
        },
        {
            text = _("Progress management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Pull progress on open"),
                        keep_menu_open = true,
                        check_callback_updates_menu = true,
                        checked_func = function()
                            return self.settings:get("sync").pull_on_open == true
                        end,
                        callback = self:safeCallback(_("Pull progress on open"),
                            function(touchmenu_instance)
                                local sync = self.settings:get("sync")
                                sync.pull_on_open = not (sync.pull_on_open == true)
                                self.settings:set("sync", sync)
                                self.settings:flush()
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end),
                     },
                    {
                        text = _("Upload progress on close"),
                        keep_menu_open = true,
                        check_callback_updates_menu = true,
                        checked_func = function()
                            return self.settings:get("sync").upload_on_close == true
                        end,
                        callback = self:safeCallback(_("Upload progress on close"),
                            function(touchmenu_instance)
                                local sync = self.settings:get("sync")
                                sync.upload_on_close =
                                    not (sync.upload_on_close == true)
                                self.settings:set("sync", sync)
                                self.settings:flush()
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end),
                    },
                }
            end,
        },
        {
            text = _("Download settings"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Book images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_book_images
                        end,
                        callback = self:safeCallback(_("Book images"), function()
                            local cache = self.settings:get("cache")
                            cache.download_book_images = not cache.download_book_images
                            self.settings:set("cache", cache)
                            self.settings:flush()
                            logger.info(
                                "image download setting changed:",
                                "target=book",
                                "enabled=", tostring(cache.download_book_images)
                            )
                        end),
                    },
                    {
                        text = _("Public account article images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:get("cache").download_mp_images
                        end,
                        check_callback_updates_menu = true,
                        callback = self:safeCallback(_("Public account article images"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            if cache.download_mp_images then
                                self:setMPImageDownload(false)
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading public account article images may significantly increase download time. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = self:safeCallback(_("Confirm"), function()
                                    self:setMPImageDownload(true)
                                    touchmenu_instance:updateItems()
                                end),
                                cancel_text = _("Cancel"),
                            })
                        end),
                    },
                    {
                        text = _("Chapter prefetch"),
                        sub_item_table_func = function()
                            return {
                                {
                                    text = _("Automatically prefetch next chapter"),
                                    keep_menu_open = true,
                                    check_callback_updates_menu = true,
                                    checked_func = function()
                                        return self.settings:get("cache").auto_prefetch_next_chapter
                                            == true
                                    end,
                                    callback = self:safeCallback(
                                        _("Automatically prefetch next chapter"),
                                        function(touchmenu_instance)
                                            local cache = self.settings:get("cache")
                                            local function apply(enabled)
                                                cache.auto_prefetch_next_chapter = enabled
                                                self.settings:set("cache", cache)
                                                self.settings:flush()
                                                if not enabled then
                                                    self.downloader:cancelPrefetch(
                                                        "setting_disabled")
                                                elseif self._current_weread_book_id then
                                                    local book_id = self._current_weread_book_id
                                                    UIManager:scheduleIn(0.1, function()
                                                        if self._current_weread_book_id == book_id then
                                                            self:maybePrefetchNextChapter(book_id)
                                                        end
                                                    end)
                                                end
                                                if touchmenu_instance then
                                                    touchmenu_instance:updateItems()
                                                end
                                            end

                                            if cache.auto_prefetch_next_chapter == true then
                                                apply(false)
                                                return
                                            end

                                            UIManager:show(ConfirmBox:new{
                                                text = _("Due to network conditions, automatic prefetching may cause a few seconds of delay when you start reading a new chapter. Enable it?"),
                                                ok_text = _("Confirm"),
                                                ok_callback = self:safeCallback(
                                                    _("Confirm"), function()
                                                        apply(true)
                                                    end),
                                                cancel_text = _("Cancel"),
                                            })
                                        end),
                                },
                                {
                                    text = _("Prefetch underlines and thoughts"),
                                    keep_menu_open = true,
                                    check_callback_updates_menu = true,
                                    enabled_func = function()
                                        return self.settings:get("cache").auto_prefetch_next_chapter
                                            == true
                                    end,
                                    checked_func = function()
                                        return self.settings:get("cache").download_underlines_and_thoughts
                                    end,
                                    callback = self:safeCallback(
                                        _("Prefetch underlines and thoughts"),
                                        function(touchmenu_instance)
                                            local cache = self.settings:get("cache")
                                            if cache.download_underlines_and_thoughts then
                                                cache.download_underlines_and_thoughts = false
                                                self.settings:set("cache", cache)
                                                self.settings:flush()
                                                logger.info(
                                                    "underlines/thoughts download setting changed:",
                                                    "enabled=", "false")
                                                touchmenu_instance:updateItems()
                                                return
                                            end
                                            UIManager:show(ConfirmBox:new{
                                                text = _("Prefetching underlines and thoughts adds extra requests and may significantly increase prefetch time. Continue?"),
                                                ok_text = _("Confirm"),
                                                ok_callback = self:safeCallback(_("Confirm"), function()
                                                    cache.download_underlines_and_thoughts = true
                                                    self.settings:set("cache", cache)
                                                    self.settings:flush()
                                                    logger.info(
                                                        "underlines/thoughts download setting changed:",
                                                        "enabled=", "true")
                                                    touchmenu_instance:updateItems()
                                                end),
                                                cancel_text = _("Cancel"),
                                            })
                                        end),
                                },
                                {
                                    text = _("Show prefetch notifications"),
                                    keep_menu_open = true,
                                    check_callback_updates_menu = true,
                                    enabled_func = function()
                                        return self.settings:get("cache").auto_prefetch_next_chapter
                                            == true
                                    end,
                                    checked_func = function()
                                        return self.settings:get("cache").show_prefetch_notifications
                                            ~= false
                                    end,
                                    callback = self:safeCallback(
                                        _("Show prefetch notifications"),
                                        function(touchmenu_instance)
                                            local cache = self.settings:get("cache")
                                            cache.show_prefetch_notifications =
                                                not (cache.show_prefetch_notifications ~= false)
                                            self.settings:set("cache", cache)
                                            self.settings:flush()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end),
                                },
                            }
                        end,
                    },
                }
            end,
        },
        {
            text = _("Underline settings"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Ignore edge taps on underlines"),
                        checked_func = function()
                            return self.settings:get("cache").ignore_edge_thought_taps ~= false
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Ignore edge taps on underlines"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            cache.ignore_edge_thought_taps = not (cache.ignore_edge_thought_taps ~= false)
                            self.settings:set("cache", cache)
                            self.settings:flush()
                            logger.info(
                                "ignore_edge_thought_taps changed:",
                                "enabled=", tostring(cache.ignore_edge_thought_taps)
                            )
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end),
                    },
                    {
                        text_func = function()
                            local ratio = tonumber(self.settings:get("cache").edge_tap_ratio) or 0.20
                            return T(_("Edge zone: %1%"), math.floor(ratio * 100 + 0.5))
                        end,
                        enabled_func = function()
                            return self.settings:get("cache").ignore_edge_thought_taps ~= false
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Edge zone"), function(touchmenu_instance)
                            self:showEdgeTapRatioPicker(touchmenu_instance)
                        end),
                    },
                    {
                        text_func = function()
                            local height = tonumber(self.settings:get("thought_popup").height_ratio) or 0.62
                            return T(_("Thought popup height: %1%"), math.floor(height * 100 + 0.5))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Thought popup height"), function(touchmenu_instance)
                            self:showThoughtPopupHeightPicker(touchmenu_instance)
                        end),
                    },
                    {
                        text = _("Thought popup font size"),
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Thought popup font size"), function()
                            self:showThoughtPopupFontSizePicker()
                        end),
                    },
                    {
                        text_func = function()
                            local contrast = tonumber(self.settings:get("thought_popup").contrast) or 0
                            if contrast == 0 then
                                return _("Thought popup font contrast: Default")
                            end
                            return T(_("Thought popup font contrast: %1"),
                                (contrast > 0 and "+" or "") .. tostring(contrast))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Thought popup font contrast"), function(touchmenu_instance)
                            self:showThoughtPopupContrastPicker(touchmenu_instance)
                        end),
                    },
                    {
                        text_func = function()
                            local position = self.settings:get("thought_popup").position or "center"
                            return T(_("Thought popup position: %1"),
                                position == "center" and _("Center") or _("Bottom"))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Thought popup position"), function(touchmenu_instance)
                            self:showThoughtPopupPositionPicker(touchmenu_instance)
                        end),
                    },
                    {
                        text_func = function()
                            local ratio = tonumber(self.settings:get("thought_popup").width_ratio) or 0.8
                            return T(_("Thought popup width: %1%"), math.floor(ratio * 100 + 0.5))
                        end,
                        enabled_func = function()
                            return (self.settings:get("thought_popup").position or "center") == "center"
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Thought popup width"), function(touchmenu_instance)
                            self:showThoughtPopupWidthPicker(touchmenu_instance)
                        end),
                    },
                    {
                        text = _("Thought popup: tap left/right to turn pages"),
                        checked_func = function()
                            return self.settings:get("thought_popup").tap_to_page == true
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Thought popup: tap left/right to turn pages"), function(touchmenu_instance)
                            local thought_popup = self.settings:get("thought_popup")
                            thought_popup.tap_to_page = not (thought_popup.tap_to_page == true)
                            self.settings:set("thought_popup", thought_popup)
                            self.settings:flush()
                            logger.info("thought popup tap_to_page changed:",
                                "enabled=", tostring(thought_popup.tap_to_page))
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end),
                    },
                }
            end,
        },
        {
            text = _("Account management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Account status"),
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Account status"), function()
                            self:showAccountStatus()
                        end),
                    },
                    {
                        text = _("Renew cookie now"),
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Renew cookie now"), function()
                            self:renewCookieWithUI()
                        end),
                    },
                    {
                        text = _("Clear account data"),
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Clear account data"), function()
                            self:confirmClearAccount()
                        end),
                    },
                }
            end,
        },
        {
            text = _("About"),
            sub_item_table_func = function()
                return self:getAboutMenuItems()
            end,
        },
    }
end

-- Open the local WeRead collection.
-- From FileManager: open in place. From the reader: leave the book first and
-- open via FileManager — showing the collection on top of ReaderUI leaves the
-- document underneath, so navigating up/closing the shelf drops back into it.
function M:showWereadCollection()
    local COLLECTION_NAME = "weread"
    local FileManager = require("apps/filemanager/filemanager")
    local ReadCollection = require("readcollection")

    if not ReadCollection.coll then
        ReadCollection:_read()
    end
    if not ReadCollection.coll[COLLECTION_NAME] then
        ReadCollection:addCollection(COLLECTION_NAME)
        ReadCollection:write({ [COLLECTION_NAME] = true })
    end

    local fm = FileManager.instance
    if fm and fm.collections then
        fm.collections:onShowColl(COLLECTION_NAME)
        return
    end
    if self.ui and self.ui.document and self.ui.showFileManager then
        local file = self.ui.document.file
        self.ui:onClose()
        self.ui:showFileManager(file)
        UIManager:scheduleIn(0.1, function()
            local fm2 = FileManager.instance
            if fm2 and fm2.collections then
                fm2.collections:onShowColl(COLLECTION_NAME)
            end
        end)
        return
    end
    if self.ui and self.ui.collections then
        self.ui.collections:onShowColl(COLLECTION_NAME)
    end
end

function M:showAbout()
    UIManager:show(InfoMessage:new{
        text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nhttps://github.com/finlater/weread.koplugin"), self.version),
    })
end

function M:getAboutMenuItems()
    local items = {
        {
            text = T(_("Version %1"), self.version),
            keep_menu_open = true,
            callback = function()
                self:showAbout()
            end,
        },
        {
            text = T(_("Author: %1"), "finlater"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = "finlater\n\nhttps://github.com/finlater",
                })
            end,
        },
    }
    for _, item in ipairs(self:getUpdateMenuItems()) do
        items[#items + 1] = item
    end
    return items
end

function M:getUpdateMenuItems()
    local items = {}
    local available = self.updater:available_version()
    if available then
        table.insert(items, {
            text = T(_("Update to v%1"), available),
            keep_menu_open = true,
            callback = self:safeCallback(_("Update plugin"), function()
                self.updater:show_cached_update()
            end),
        })
    else
        table.insert(items, {
            text = _("Check for updates"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Check for updates"), function()
                self.updater:check(true)
            end),
        })
    end
    table.insert(items, {
        text = _("Automatically check once a day"),
        keep_menu_open = true,
        check_callback_updates_menu = true,
        checked_func = function()
            return self.settings:get("update").auto_check == true
        end,
        callback = self:safeCallback(_("Automatically check once a day"),
            function(touchmenu_instance)
                local update = self.settings:get("update")
                update.auto_check = not (update.auto_check == true)
                self.settings:set("update", update)
                self.settings:flush()
                if update.auto_check then self.updater:schedule_auto_check() end
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end),
    })
    table.insert(items, {
        text = _("Prefer proxy for updates"),
        keep_menu_open = true,
        check_callback_updates_menu = true,
        checked_func = function()
            return self.settings:get("update").prefer_proxy == true
        end,
        callback = self:safeCallback(_("Prefer proxy for updates"),
            function(touchmenu_instance)
                local update = self.settings:get("update")
                local function apply(enabled)
                    update.prefer_proxy = enabled
                    self.settings:set("update", update)
                    self.settings:flush()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end
                if update.prefer_proxy == true then
                    apply(false)
                    return
                end
                UIManager:show(ConfirmBox:new{
                    text = _("Update proxies are third-party services. They can see update requests and may be unavailable without notice. Release packages will still be verified before installation. Prefer proxies?"),
                    ok_text = _("Enable"),
                    cancel_text = _("Cancel"),
                    ok_callback = function() apply(true) end,
                })
            end),
    })
    return items
end

-- Let the user set the thought popup height as a percentage of the screen.
function M:showThoughtPopupHeightPicker(touchmenu_instance)
    local SpinWidget = require("ui/widget/spinwidget")
    local current = math.floor((tonumber(self.settings:get("thought_popup").height_ratio) or 0.62) * 100)
    local spin = SpinWidget:new{
        value = current,
        value_min = 20,
        value_max = 90,
        value_step = 5,
        precision = "%d%%",
        ok_text = _("Set height"),
        title_text = _("Thought popup height"),
        info_text = _("Set the thought popup height as a percentage of the screen height (20%-90%)."),
        callback = function(spin_widget)
            local thought_popup = self.settings:get("thought_popup")
            thought_popup.height_ratio = spin_widget.value / 100
            self.settings:set("thought_popup", thought_popup)
            self.settings:flush()
            logger.info("thought popup height changed:",
                "ratio=", tostring(thought_popup.height_ratio))
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }
    UIManager:show(spin)
end

-- Set the thought popup font size: a fixed absolute size or a size relative
-- to the document font. Mirrors KOReader's footnote popup font size setting
-- (frontend/apps/reader/modules/readerlink.lua).
function M:showThoughtPopupFontSizePicker()
    local Screen = require("device").screen
    local thought_popup = self.settings:get("thought_popup")
    local spin_widget
    local get_font_size_widget
    get_font_size_widget = function(show_absolute_font_size_widget)
        local SpinWidget = require("ui/widget/spinwidget")
        if show_absolute_font_size_widget then
            spin_widget = SpinWidget:new{
                width = math.floor(Screen:getWidth() * 0.75),
                value = tonumber(thought_popup.font_size)
                        or Screen:scaleBySize((self.ui
                            and self.ui.document
                            and self.ui.document.configurable
                            and self.ui.document.configurable.font_size) or 18),
                value_min = 12,
                value_max = 255,
                precision = "%d",
                ok_text = _("Set font size"),
                title_text = _("Thought popup font size"),
                info_text = _([[
The thought popup font adjusts to the font size you've set for the document, but you can specify here a fixed absolute font size to be used instead.]]),
                callback = function(spin)
                    local tp = self.settings:get("thought_popup")
                    tp.font_size = spin.value
                    tp.font_size_relative = nil
                    self.settings:set("thought_popup", tp)
                    self.settings:flush()
                    logger.info("thought popup font size changed:", "absolute=", spin.value)
                end,
                extra_text = _("Set a relative font size instead"),
                extra_callback = function()
                    UIManager:close(spin_widget)
                    spin_widget = get_font_size_widget(false)
                    UIManager:show(spin_widget)
                end,
            }
        else
            spin_widget = SpinWidget:new{
                width = math.floor(Screen:getWidth() * 0.75),
                value = tonumber(thought_popup.font_size_relative) or -2,
                value_min = -10,
                value_max = 5,
                precision = "%+d",
                ok_text = _("Set font size"),
                title_text = _("Thought popup font size"),
                info_text = _([[
The thought popup font adjusts to the font size you've set for the document.
You can specify here how much smaller or larger it should be relative to the document font size.
A negative value will make it smaller, while a positive one will make it larger.
The recommended value is -2.]]),
                callback = function(spin)
                    local tp = self.settings:get("thought_popup")
                    tp.font_size_relative = spin.value
                    tp.font_size = nil
                    self.settings:set("thought_popup", tp)
                    self.settings:flush()
                    logger.info("thought popup font size changed:", "relative=", spin.value)
                end,
                extra_text = _("Set an absolute font size instead"),
                extra_callback = function()
                    UIManager:close(spin_widget)
                    spin_widget = get_font_size_widget(true)
                    UIManager:show(spin_widget)
                end,
            }
        end
        return spin_widget
    end
    spin_widget = get_font_size_widget(thought_popup.font_size ~= nil)
    UIManager:show(spin_widget)
end

-- Set the thought popup text contrast: positive values darken the text,
-- negative values lighten it (0 = the default light gray shades).
function M:showThoughtPopupContrastPicker(touchmenu_instance)
    local SpinWidget = require("ui/widget/spinwidget")
    local current = tonumber(self.settings:get("thought_popup").contrast) or 0
    local spin = SpinWidget:new{
        value = current,
        value_min = -3,
        value_max = 9,
        precision = "%+d",
        ok_text = _("Set contrast"),
        title_text = _("Thought popup font contrast"),
        info_text = _([[
The thought popup text is rendered in light gray shades. Increase the contrast to darken the text (the maximum renders pure black), decrease it to lighten it.]]),
        callback = function(spin_widget)
            local thought_popup = self.settings:get("thought_popup")
            thought_popup.contrast = spin_widget.value
            self.settings:set("thought_popup", thought_popup)
            self.settings:flush()
            logger.info("thought popup contrast changed:",
                "contrast=", tostring(thought_popup.contrast))
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }
    UIManager:show(spin)
end

-- Let the user choose where the thought popup appears: bottom (the solid-line
-- bar) or centered (the TextViewer-style window with page buttons).
function M:showThoughtPopupPositionPicker(touchmenu_instance)
    local current = self.settings:get("thought_popup").position or "center"
    local buttons = {}
    for _i, choice in ipairs({
        { key = "bottom", label = _("Bottom") },
        { key = "center", label = _("Center") },
    }) do
        local label = choice.label
        if choice.key == current then
            label = label .. "  ✓"
        end
        table.insert(buttons, {
            {
                text = label,
                callback = function()
                    UIManager:close(self._thought_popup_position_dialog)
                    self._thought_popup_position_dialog = nil
                    local thought_popup = self.settings:get("thought_popup")
                    thought_popup.position = choice.key
                    self.settings:set("thought_popup", thought_popup)
                    self.settings:flush()
                    logger.info("thought popup position changed:",
                        "position=", tostring(thought_popup.position))
                    -- Close any open popup; the next open uses the new position.
                    ThoughtPopup.closeVisible()
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self._thought_popup_position_dialog)
                self._thought_popup_position_dialog = nil
            end,
        },
    })
    self._thought_popup_position_dialog = ButtonDialog:new{
        title = _("Thought popup position"),
        buttons = buttons,
    }
    UIManager:show(self._thought_popup_position_dialog)
end

-- Set the centered thought popup width as a percentage of the screen width.
-- Only meaningful when the popup position is "center".
function M:showThoughtPopupWidthPicker(touchmenu_instance)
    local SpinWidget = require("ui/widget/spinwidget")
    local current = math.floor((tonumber(self.settings:get("thought_popup").width_ratio) or 0.8) * 100)
    local spin = SpinWidget:new{
        value = current,
        value_min = 40,
        value_max = 100,
        value_step = 5,
        precision = "%d%%",
        ok_text = _("Set width"),
        title_text = _("Thought popup width"),
        info_text = _("Set the centered thought popup width as a percentage of the screen width (40%-100%)."),
        callback = function(spin_widget)
            local thought_popup = self.settings:get("thought_popup")
            thought_popup.width_ratio = spin_widget.value / 100
            self.settings:set("thought_popup", thought_popup)
            self.settings:flush()
            logger.info("thought popup width changed:",
                "ratio=", tostring(thought_popup.width_ratio))
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }
    UIManager:show(spin)
end

-- Let the user pick how wide the left/right page-turn edge zone is (percent of
-- screen width on each side). Only used when ignore_edge_thought_taps is on.
function M:showEdgeTapRatioPicker(touchmenu_instance)
    local choices = { 0.10, 0.15, 0.20, 0.25, 0.30, 0.40 }
    local current = tonumber(self.settings:get("cache").edge_tap_ratio) or 0.20
    local buttons = {}
    for _i, ratio in ipairs(choices) do
        local pct = math.floor(ratio * 100 + 0.5)
        local label = T(_("%1%"), pct)
        if math.abs(ratio - current) < 0.001 then
            label = label .. "  ✓"
        end
        table.insert(buttons, {
            {
                text = label,
                callback = function()
                    UIManager:close(self._edge_ratio_dialog)
                    self._edge_ratio_dialog = nil
                    local cache = self.settings:get("cache")
                    cache.edge_tap_ratio = ratio
                    self.settings:set("cache", cache)
                    self.settings:flush()
                    logger.info("edge_tap_ratio changed:", "ratio=", tostring(ratio))
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self._edge_ratio_dialog)
                self._edge_ratio_dialog = nil
            end,
        },
    })
    self._edge_ratio_dialog = ButtonDialog:new{
        title = _("Edge zone width (each side)"),
        buttons = buttons,
    }
    UIManager:show(self._edge_ratio_dialog)
end

return M
