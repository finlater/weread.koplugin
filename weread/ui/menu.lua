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
    Dispatcher:registerAction("weread_sync_progress", {
        category = "none",
        event = "WeReadSyncProgress",
        title = _("WeRead · Sync reading progress"),
        reader = true,
    })
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
        {
            text = _("Plugin update"),
            sub_item_table_func = function()
                return self:getUpdateMenuItems()
            end,
        },
        {
            text = T(_("About (v%1)"), self.version),
            keep_menu_open = true,
            callback = function()
                local version = self.version
                if self.getUpdater then
                    version = self:getUpdater():get_local_version() or version
                end
                UIManager:show(InfoMessage:new{
                    text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nhttps://github.com/rollingshmily/weread.koplugin"), version),
                })
            end,
        },
    }

    if self.ui.document then
        table.insert(items, 2, {
            text = _("Sync progress now"),
            keep_menu_open = true,
            enabled_func = function()
                local book_id = self:detectWeReadBook()
                return book_id ~= nil and not WeRead.is_mp_book(book_id)
            end,
            callback = self:safeCallback(_("Sync progress now"), function()
                self:onWeReadSyncProgress()
            end),
        })
        table.insert(items, 3, {
            text = _("Book details"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Book details"), function()
                self:showCurrentBookDetails()
            end),
        })
        table.insert(items, 4, {
            text = _("Show underlines and thoughts"),
            checked_func = function()
                return self.settings:get("cache").show_annotations ~= false
            end,
            keep_menu_open = true,
            callback = self:safeCallback(_("Show underlines and thoughts"), function()
                local cache = self.settings:get("cache")
                cache.show_annotations = not (cache.show_annotations ~= false)
                self.settings:set("cache", cache)
                self.settings:flush()
                logger.info(
                    "annotation visibility changed:",
                    "show=", tostring(cache.show_annotations)
                )
                -- Keep the tap interception registered in both states; hiding is
                -- handled by _onThoughtTap. Just close any popup already showing.
                if not cache.show_annotations then
                    ThoughtPopup.closeVisible()
                    self._thought_popup_open = nil
                end
                self:applyAnnotationVisibility()
            end),
        })
    end

    return items
end

function M:getSettingsMenuItems()
    return {
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
                            return T(_("Book directory: %1"), BD.dirpath(self.settings:get_download_dir()))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Book directory"), function(touchmenu_instance)
                            self:showDownloadDirPicker(touchmenu_instance)
                        end),
                    },
                    {
                        text_func = function()
                            return T(_("Metadata directory: %1"), BD.dirpath(self.settings:get_meta_dir()))
                        end,
                        keep_menu_open = true,
                        callback = self:safeCallback(_("Metadata directory"), function(touchmenu_instance)
                            self:showMetaDirPicker(touchmenu_instance)
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

                        callback = self:safeCallback(_("Underlines and thoughts"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            if cache.download_underlines_and_thoughts then
                                cache.download_underlines_and_thoughts = false
                                self.settings:set("cache", cache)
                                self.settings:flush()
                                logger.info(
                                    "underlines/thoughts download setting changed:", "enabled=", "false")
                                touchmenu_instance:updateItems()
                                return
                            end
                            UIManager:show(ConfirmBox:new{
                                text = _("Downloading underlines and thoughts adds requests for every chapter and may significantly increase download time and cache usage. Continue?"),
                                ok_text = _("Confirm"),
                                ok_callback = self:safeCallback(_("Confirm"), function()
                                    cache.download_underlines_and_thoughts = true
                                    self.settings:set("cache", cache)
                                    self.settings:flush()
                                    logger.info(
                                        "underlines/thoughts download setting changed:", "enabled=", "true")
                                    touchmenu_instance:updateItems()
                                end),
                                cancel_text = _("Cancel"),
                            })
                        end),

                    },
                }
            end,
        },
        {
            text = _("Thoughts"),
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
    }
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
