local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local Menu = require("ui/widget/menu")
local PathChooser = require("ui/widget/pathchooser")
local time = require("ui/time")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template

local Annotations = require("lib.annotations")
local Client = require("lib.client")
local Content = require("lib.content")
local Downloader = require("lib.downloader")
local EndOfBookDialog = require("ui.end_of_book_dialog")
local I18n = require("lib.i18n")
local Scan = require("lib.scan")
local QRLogin = require("lib.qr_login")
local ReadReport = require("lib.read_report")
local ReadStats = require("lib.read_stats")
local ReadStatsView = require("ui.read_stats_view")
local Settings = require("lib.settings")
local Thoughts = require("lib.thoughts")
local WeRead = require("lib.weread")
local ThoughtPopup = require("ui.thought_popup")

-- `_` is the translation function; never reuse it as a loop placeholder in this file.
local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"
local unpack_args = unpack or table.unpack

-- Hard ceilings for the per-session thought caches (both cleared on book close).
-- On overflow the whole map is dropped; the next tap simply re-renders / re-reads.
local THOUGHT_HTML_CACHE_MAX = 300  -- distinct tapped underlines
local THOUGHT_JSON_CACHE_MAX = 10   -- distinct chapters with thoughts

local function thought_perf(stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.dbg(LOG_MODULE, "thought_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed), ...)
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function file_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = "0.1.1",
}

function WeReadPlugin:init()
    math.randomseed(os.time())
    self.settings = Settings:new()
    self.client = Client:new(self.settings)
    self.downloader = Downloader:new{
        client = self.client,
        settings = self.settings,
        show_info       = function(text) self:showInfo(text) end,
        show_transient  = function(text, timeout) self:showTransientInfo(text, timeout) end,
        refresh_ui      = function() self:refreshUI() end,
        refresh_shelf   = function() self:refreshShelfCacheIndicators() end,
        open_file       = function(path) self:openFile(path) end,
        safe_callback   = function(label, fn) return self:safeCallback(label, fn) end,
        require_login   = function(cookie, api_key) return self:requireLogin(cookie, api_key) end,
        run_online_task = function(label, fn) self:runOnlineTask(label, fn) end,
    }
    self:migrateLegacyBookData()
    self.qr_login = QRLogin:new(self, self.client, self.settings)
    self.read_report = ReadReport:new{
        settings = self.settings,
        client = self.client,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        is_online = function()
            return self:isNetworkOnline()
        end,
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local read_report = self.settings:get("read_report")
    if read_report.enabled
        and read_report.mode == "manual"
        and read_report.book_id ~= ""
        and read_report.report_on_open == false then
        self.read_report:maybe_start("plugin_start")
    end
    ThoughtPopup.init()
    self._reader_session_gen = 0
    logger.info(LOG_MODULE, "initialized:", "version=", self.version)
end

function WeReadPlugin:migrateLegacyBookData()
    local books = self.settings:get("books", {})
    local found, migrated, failed = false, 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.chapters ~= nil then
            found = true
            if type(book.chapters) == "table" then
                local ok, saved = pcall(Content.save_catalog_cache,
                    self.client, self.settings, book, book.chapters)
                if ok and saved then
                    migrated = migrated + 1
                else
                    failed = failed + 1
                end
            end
            book.chapters = nil
        end
    end
    if found or self.settings:has_legacy_book_records() then
        local ok, err = pcall(function()
            self.settings:set("books", books)
            self.settings:flush()
        end)
        if ok then
            logger.info(LOG_MODULE, "legacy per-book data migrated:",
                "catalogs=", tostring(migrated), "catalog_failures=", tostring(failed))
        else
            logger.err(LOG_MODULE, "legacy per-book data migration failed:", log_error(err))
        end
    end
end

function WeReadPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("weread_show", {
        category = "none",
        event = "ShowWeRead",
        title = _("WeRead"),
        filemanager = true,
        reader = true,
    })
    Dispatcher:registerAction("weread_sync_progress", {
        category = "none",
        event = "WeReadSyncProgress",
        title = _("Sync WeRead progress"),
        reader = true,
    })
end

function WeReadPlugin:addToMainMenu(menu_items)
    menu_items.weread = {
        text = _("WeRead"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
    }
end

function WeReadPlugin:safeCallback(label, callback)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "action failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

function WeReadPlugin:getMainMenuItems()
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
            text = T(_("About (v%1)"), self.version),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nhttps://github.com/finlater/weread.koplugin"), self.version),
                })
            end,
        },
    }

    if self.ui.document then
        table.insert(items, 2, {
            text = _("Sync progress now") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 3, {
            text = _("Book details"),
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
                    LOG_MODULE,
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

function WeReadPlugin:getSettingsMenuItems()
    return {
        {
            text = _("Cache management"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Scan and match local books"),
                        callback = self:safeCallback(_("Scan and match local books"), function()
                            self:confirmScanLocalCache()
                        end),
                    },
                    {
                        text = _("Cache cleanup"),
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
                        enabled_func = function() return false end,
                        checked_func = function()
                            return self.settings:get("sync").pull_on_open
                        end,
                    },
                    {
                        text = _("Upload progress on close"),
                        enabled_func = function() return false end,
                        checked_func = function()
                            return self.settings:get("sync").upload_on_close
                        end,
                    },
                }
            end,
        },
        {
            text = _("Download content"),
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
                                LOG_MODULE,
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
                        text = _("Underlines and thoughts"),
                        keep_menu_open = true,
                        check_callback_updates_menu = true,
                        checked_func = function()
                            return self.settings:get("cache").download_underlines_and_thoughts
                        end,
                        callback = self:safeCallback(_("Underlines and thoughts"), function(touchmenu_instance)
                            local cache = self.settings:get("cache")
                            if cache.download_underlines_and_thoughts then
                                cache.download_underlines_and_thoughts = false
                                self.settings:set("cache", cache)
                                self.settings:flush()
                                logger.info(LOG_MODULE,
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
                                    logger.info(LOG_MODULE,
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
                                LOG_MODULE,
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
function WeReadPlugin:showEdgeTapRatioPicker(touchmenu_instance)
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
                    logger.info(LOG_MODULE, "edge_tap_ratio changed:", "ratio=", tostring(ratio))
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

function WeReadPlugin:setMPImageDownload(enabled)
    local cache = self.settings:get("cache")
    cache.download_mp_images = enabled == true
    self.settings:set("cache", cache)
    self.settings:flush()
    logger.info(
        LOG_MODULE,
        "image download setting changed:",
        "target=mp",
        "enabled=", tostring(cache.download_mp_images)
    )
end

-- Returns true if the directory is usable (creatable and writable), else false + message.
function WeReadPlugin:validateDownloadDir(path)
    local lfs = require("libs/libkoreader-lfs")
    if type(path) ~= "string" or path == "" then
        return false, _("Invalid path.")
    end
    if not lfs.attributes(path, "mode") then
        os.execute("mkdir -p " .. string.format("%q", path))
        if not lfs.attributes(path, "mode") then
            return false, _("Directory does not exist and could not be created.")
        end
    end
    local test_file = path .. "/.weread_write_test"
    local f = io.open(test_file, "w")
    if not f then
        return false, _("Directory is not writable.")
    end
    f:close()
    os.remove(test_file)
    return true
end

function WeReadPlugin:showDownloadDirPicker(touchmenu_instance)
    local current = self.settings:get_download_dir()
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = current,
        onConfirm = function(path)
            local ok, err = self:validateDownloadDir(path)
            if not ok then
                self:showInfo(T(_("Cannot use this directory: %1"), err))
                return
            end
            local old_dir = self.settings:get_download_dir()
            self.settings:set_download_dir(path)
            logger.info(LOG_MODULE, "download directory changed:", path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            self:offerMoveBooksToNewDir(old_dir, path)
        end,
    }
    UIManager:show(path_chooser)
end

-- After the download directory changes, offer to move already-cached books from
-- their old locations into the new directory. Without this, old files stay behind
-- as orphans (still reachable via the stored paths, but not under the new root).
function WeReadPlugin:offerMoveBooksToNewDir(old_dir, new_dir)
    if old_dir == new_dir then
        self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local movable = {}
    for book_id, book in pairs(books) do
        local src = Content.book_resolved_dir(self.settings, book_id, book)
        local dst = Content.book_cache_dir(self.settings, book_id)
        if src ~= dst then
            local attr = lfs.attributes(src)
            if attr and attr.mode == "directory" then
                table.insert(movable, { book_id = book_id, src = src, dst = dst })
            end
        end
    end
    if #movable == 0 then
        self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1"), new_dir))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Download directory changed. Move %1 cached book(s) to the new location?"), tostring(#movable)),
        ok_text = _("Move"),
        ok_callback = function()
            self:moveBooksToNewDir(movable, new_dir)
        end,
        cancel_text = _("Keep"),
        cancel_callback = function()
            self:offerScanNewDir(new_dir, T(_("Download directory set to:\n%1\nExisting downloads stay in the old location."), new_dir))
        end,
    })
end

function WeReadPlugin:moveBooksToNewDir(movable, new_dir)
    self:showBusy(_("Moving cached books..."))
    UIManager:scheduleIn(0.1, function()
        local books = self.settings:get("books", {})
        local moved, skipped, failed = 0, 0, 0
        for _i, m in ipairs(movable) do
            local ok, reason = self:moveBookDir(m.src, m.dst)
            if ok then
                local book = books[m.book_id]
                if book then
                    book.cache_dir = m.dst
                    book.cached_file = self:remapCachedPath(book.cached_file, m.dst)
                    if type(book.cached_chapters) == "table" then
                        for uid, path in pairs(book.cached_chapters) do
                            book.cached_chapters[uid] = self:remapCachedPath(path, m.dst)
                        end
                    end
                end
                moved = moved + 1
            elseif reason == "target_exists" then
                skipped = skipped + 1
                logger.warn(LOG_MODULE, "skip move, target exists:", m.dst)
            else
                failed = failed + 1
                logger.err(LOG_MODULE, "move book cache failed:", m.src, "->", m.dst)
            end
        end
        self.settings:set("books", books)
        self.settings:flush()
        self:closeBusy()
        local message
        if skipped == 0 and failed == 0 then
            message = T(_("Moved %1 book(s) to:\n%2"), tostring(moved), new_dir)
        else
            message = T(_("Moved %1 book(s). %2 skipped (target already exists), %3 failed. These stay in the old location."), tostring(moved), tostring(skipped), tostring(failed))
        end
        self:offerScanNewDir(new_dir, message)
    end)
end

-- Move one book directory to dst. Uses `mv`, which (unlike os.rename) handles
-- moves across filesystems, e.g. internal storage to an SD card. Returns
-- true on success, or false plus a reason ("target_exists" / "move_failed").
function WeReadPlugin:moveBookDir(src, dst)
    if src == dst then
        return true
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dst) then
        -- The target already exists. Since the new directory is user-selected, it
        -- may be unrelated user data that only happens to share the sanitized name.
        -- Never delete it; leave the book in its old location instead.
        return false, "target_exists"
    end
    local parent = dst:match("^(.*)/[^/]+$")
    if parent then
        os.execute("mkdir -p " .. string.format("%q", parent))
    end
    local status = os.execute("mv -f " .. string.format("%q", src) .. " " .. string.format("%q", dst))
    if status == true or status == 0 then
        return true
    end
    return false, "move_failed"
end

-- Rewrite a stored absolute file path to sit under the new book directory,
-- keeping the original filename.
function WeReadPlugin:remapCachedPath(path, dst)
    if type(path) ~= "string" then
        return path
    end
    local name = path:match("[^/]+$")
    if not name then
        return path
    end
    return dst .. "/" .. name
end

local SHELF_SORT_OPTIONS = {
    { key = "time_desc", label = _("Last read time (newest first)") },
    { key = "time_asc",  label = _("Last read time (oldest first)") },
    { key = "default",   label = _("Default order") },
    { key = "name_asc",  label = _("Title A-Z") },
    { key = "name_desc", label = _("Title Z-A") },
}

local function shelfSortLabel(sort_key)
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        if opt.key == sort_key then
            return opt.label
        end
    end
    return SHELF_SORT_OPTIONS[1].label
end

local SHELF_FILTER_OPTIONS = {
    { dim = "reading",  value = "finished",       label = _("Only show finished books"),       short = _("Finished") },
    { dim = "reading",  value = "unfinished",     label = _("Only show unfinished books"),     short = _("Unfinished") },
    { dim = "download", value = "downloaded",     label = _("Only show downloaded books"),     short = _("Downloaded") },
    { dim = "download", value = "not_downloaded", label = _("Only show not-downloaded books"), short = _("Not downloaded") },
}

function WeReadPlugin:shelfFilterSummary()
    local filters = self.shelf_filters
    local parts = {}
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        if filters[opt.dim] == opt.value then
            table.insert(parts, opt.short)
        end
    end
    if #parts == 0 then
        return _("All")
    end
    return table.concat(parts, " / ")
end

function WeReadPlugin:saveShelfFilters()
    local shelf = self.settings:get("shelf")
    shelf.filter_reading = self.shelf_filters.reading
    shelf.filter_download = self.shelf_filters.download
    self.settings:set("shelf", shelf)
    self.settings:flush()
end

function WeReadPlugin:bookMatchesFilters(book, saved_books, downloaded_cache)
    local filters = self.shelf_filters or {}
    if filters.reading == "finished" and book.finishReading ~= 1 then return false end
    if filters.reading == "unfinished" and book.finishReading == 1 then return false end
    if filters.download then
        local is_downloaded = self:isBookDownloaded(book, saved_books, downloaded_cache)
        if filters.download == "downloaded" and not is_downloaded then return false end
        if filters.download == "not_downloaded" and is_downloaded then return false end
    end
    return true
end

function WeReadPlugin:showShelfSortOptions(on_sorted)
    local dialog
    local current_sort = self.settings:get("shelf").sort_order or "default"
    local buttons = {}
    for _i, opt in ipairs(SHELF_SORT_OPTIONS) do
        table.insert(buttons, {
            {
                text = opt.label,
                checked_func = function()
                    return opt.key == current_sort
                end,
                -- Defer close+refresh so Button's post-tap checkmark repaint runs
                -- against the still-shown dialog (avoids a ghost label on close).
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        local shelf = self.settings:get("shelf")
                        shelf.sort_order = opt.key
                        self.settings:set("shelf", shelf)
                        self.settings:flush()
                        on_sorted()
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Sort by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function WeReadPlugin:showShelfFilterOptions(on_changed)
    local dialog
    local filters = self.shelf_filters
    local buttons = {
        {
            {
                text = _("All"),
                checked_func = function()
                    return filters.reading == nil and filters.download == nil
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        filters.reading = nil
                        filters.download = nil
                        self:saveShelfFilters()
                        on_changed()
                    end)
                end,
            },
        },
    }
    for _i, opt in ipairs(SHELF_FILTER_OPTIONS) do
        table.insert(buttons, {
            {
                text = opt.label,
                checked_func = function()
                    return filters[opt.dim] == opt.value
                end,
                callback = function()
                    UIManager:nextTick(function()
                        UIManager:close(dialog)
                        -- Toggle within the dimension: re-tapping clears it, else select.
                        filters[opt.dim] = (filters[opt.dim] == opt.value) and nil or opt.value
                        self:saveShelfFilters()
                        on_changed()
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Filter by"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function WeReadPlugin:isBookDownloaded(book, saved_books, downloaded_cache)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return false
    end
    if downloaded_cache and downloaded_cache[book_id] ~= nil then
        return downloaded_cache[book_id]
    end
    local record = (saved_books or self.settings:get("books", {}))[book_id]
    local is_downloaded = record ~= nil and file_exists(record.cached_file)
    if downloaded_cache then
        downloaded_cache[book_id] = is_downloaded
    end
    return is_downloaded
end

function WeReadPlugin:shelfToolbarItems(with_filters, refresh)
    local sort_order = self.settings:get("shelf").sort_order
    local items = {
        {
            text = _("Sort"),
            mandatory = T(_("%1 \u{25BE}"), shelfSortLabel(sort_order)),
            callback = self:safeCallback(_("Sort"), function()
                self:showShelfSortOptions(refresh)
            end),
        },
    }
    if with_filters then
        table.insert(items, {
            text = _("Filter"),
            mandatory = T(_("%1 \u{25BE}"), self:shelfFilterSummary()),
            callback = self:safeCallback(_("Filter"), function()
                self:showShelfFilterOptions(refresh)
            end),
        })
    end
    items[#items].separator = true -- divide the toolbar rows from the book list
    return items
end

function WeReadPlugin:showCacheManagement()
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local items = {}
    local entries = {}
    local seen_dirs = {}
    local total_size = 0
    local mp_total_size = 0

    local function directory_stats(path)
        local size = 0
        local file_count = 0
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then
            return size, file_count
        end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local child = path .. "/" .. entry
                local attr = lfs.attributes(child)
                if attr and attr.mode == "file" then
                    size = size + (attr.size or 0)
                    file_count = file_count + 1
                elseif attr and attr.mode == "directory" then
                    local child_size, child_count = directory_stats(child)
                    size = size + child_size
                    file_count = file_count + child_count
                end
            end
        end
        return size, file_count
    end

    local function add_cache_entry(book_id, title, book_dir)
        if seen_dirs[book_dir] then
            return
        end
        seen_dirs[book_dir] = true
        local size, file_count = directory_stats(book_dir)
        if file_count == 0 then
            return
        end
        local is_mp = WeRead.is_mp_book(book_id)
        total_size = total_size + size
        if is_mp then
            mp_total_size = mp_total_size + size
        end
        table.insert(entries, {
            book_id = book_id,
            title = title or book_id,
            size = size,
            file_count = file_count,
            is_mp = is_mp,
        })
    end

    -- Only list plugin-owned entries tracked in the books table. Scanning the
    -- filesystem would list unrelated subfolders when cache_dir is a user-selected
    -- library directory, and deleting one would rm -rf a non-WeRead folder.
    for book_id, book in pairs(books) do
        add_cache_entry(book_id, book.title, Content.book_resolved_dir(self.settings, book_id, book))
    end

    table.sort(entries, function(a, b)
        if a.is_mp ~= b.is_mp then
            return a.is_mp
        end
        return tostring(a.title):lower() < tostring(b.title):lower()
    end)

    local total_str = total_size < 1024 * 1024
        and string.format("%.0f KB", total_size / 1024)
        or string.format("%.1f MB", total_size / 1024 / 1024)
    local mp_total_str = mp_total_size < 1024 * 1024
        and string.format("%.0f KB", mp_total_size / 1024)
        or string.format("%.1f MB", mp_total_size / 1024 / 1024)
    table.insert(items, {
        text = T(_("[Cleanup] Clear all public account cache (%1)"), mp_total_str),
        callback = self:safeCallback(_("Clear all public account cache"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all public account cache? Downloaded articles and cached article lists will be deleted."),
                ok_text = _("Clear"),
                ok_callback = function()
                    self:clearAllMPCache()
                    self:refreshCacheManagement(_("Public account cache cleared"))
                end,
            })
        end),
    })
    table.insert(items, {
        text = T(_("[Cleanup] Clear all cache (%1)"), total_str),
        separator = true,
        callback = self:safeCallback(_("Clear all cache"), function()
            UIManager:show(ConfirmBox:new{
                text = _("Clear all cache? Downloaded books and articles will be deleted."),
                ok_text = _("Clear"),
                ok_callback = function()
                    self:clearAllCache()
                    self:refreshCacheManagement(_("Cache cleared"))
                end,
            })
        end),
    })

    for entry_index, entry in ipairs(entries) do
        local size_str = entry.size < 1024 * 1024
            and string.format("%.0f KB", entry.size / 1024)
            or string.format("%.1f MB", entry.size / 1024 / 1024)
        table.insert(items, {
            text = entry.title,
            post_text = T(_("%1 files, %2"), tostring(entry.file_count), size_str),
            mandatory = entry.is_mp and _("Public Account") or "",
            callback = self:safeCallback(entry.title, function()
                self:confirmClearBookCache(entry.book_id, entry.title)
            end),
        })
    end

    self.cache_menu = self:showList(_("Cache management"), items, _("No cached items"))
end

function WeReadPlugin:refreshCacheManagement(message)
    if self.cache_menu then
        UIManager:close(self.cache_menu)
        self.cache_menu = nil
    end
    self:showCacheManagement()
    if message then
        self:showTransientInfo(message)
    end
end

-- Register manually copied content under a download root into the books table.
-- Only directories whose name matches a shelf book id in `allowed` are imported
-- (see lib/scan.lua), so unrelated folders in a user-selected download dir can
-- never be registered and later removed by cache cleanup.
function WeReadPlugin:scanLocalCache(root, allowed, dry_run)
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local added, updated = Scan.scan_root({
        root = root,
        fs = lfs,
        books = books,
        allowed = allowed,
        is_mp = WeRead.is_mp_book,
        dry_run = dry_run,
        now = os.time(),
    })
    if not dry_run then
        self.settings:set("books", books)
        self.settings:flush()
    end
    return added, updated
end

-- Build the set of importable directory names from the user's WeRead shelf.
-- Must be called from an online context; raises on API failure.
function WeReadPlugin:fetchShelfAllowedMap()
    local result = self.client:gateway("/shelf/sync", {})
    local allowed = {}
    for _i, book in ipairs(result and result.books or {}) do
        if book.bookId then
            allowed[Content.book_dir_name(book.bookId)] = {
                book_id = book.bookId,
                title = book.title,
                author = book.author,
            }
        end
    end
    return allowed
end

function WeReadPlugin:confirmScanLocalCache()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Scanning requires the official API key to match folders against your WeRead shelf."))
        return
    end
    self:runOnlineTask(_("Scan and match local books"), function()
        self:showBusy(_("Scanning local cache..."))
        local ok, allowed = pcall(function()
            return self:fetchShelfAllowedMap()
        end)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "scan shelf fetch failed:", log_error(allowed))
            self:showInfo(T(_("%1 failed:\n%2"), _("Scan and match local books"), display_error(allowed)))
            return
        end
        local added, updated = self:scanLocalCache(self.settings.cache_dir, allowed)
        self:closeBusy()
        self:refreshCacheManagement(T(_("Scan complete. %1 added, %2 updated."),
            tostring(added), tostring(updated)))
    end)
end

-- After the download directory changes, offer to register untracked items
-- already sitting in the new directory (e.g. manually copied in), as well as
-- known books whose stored paths became stale and need rebinding to the files
-- found here. base_message is shown when there is nothing to import or the user
-- skips. Importing requires matching against the shelf, so without an API key
-- or network the scan is silently skipped; it can be run later from Cache
-- management.
function WeReadPlugin:offerScanNewDir(new_dir, base_message)
    if not self.settings:is_api_configured() or not self:isNetworkOnline() then
        self:showInfo(base_message)
        return
    end
    self:runOnlineTask(_("Scan and match local books"), function()
        local ok, allowed = pcall(function()
            return self:fetchShelfAllowedMap()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "skip scan, shelf fetch failed:", log_error(allowed))
            self:showInfo(base_message)
            return
        end
        local pending_added, pending_updated = self:scanLocalCache(new_dir, allowed, true)
        if pending_added + pending_updated == 0 then
            self:showInfo(base_message)
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Found %1 new and %2 outdated item(s) in the new directory. Import them?"),
                tostring(pending_added), tostring(pending_updated)),
            ok_text = _("Import"),
            ok_callback = function()
                local added, updated = self:scanLocalCache(new_dir, allowed)
                self:showInfo(T(_("Imported %1 new and %2 updated item(s)."), tostring(added), tostring(updated)))
            end,
            cancel_text = _("Skip"),
            cancel_callback = function()
                self:showInfo(base_message)
            end,
        })
    end)
end

function WeReadPlugin:confirmClearBookCache(book_id, title, on_cleared)
    UIManager:show(ConfirmBox:new{
        text = T(_("Clear cache for \"%1\"?"), title),
        ok_text = _("Clear"),
        ok_callback = function()
            self:clearBookCache(book_id)
            if on_cleared then
                on_cleared()
                self:showTransientInfo(_("Cache cleared"))
            else
                self:refreshCacheManagement(_("Cache cleared"))
            end
        end,
    })
end

function WeReadPlugin:clearBookCache(book_id)
    local books = self.settings:get("books", {})
    local cache_dir = Content.book_resolved_dir(self.settings, book_id, books[book_id])
    os.execute("rm -rf " .. string.format("%q", cache_dir))
    if books[book_id] then
        books[book_id] = nil
        self.settings:set("books", books)
        self.settings:flush()
    end
    self:refreshShelfCacheIndicators()
end

function WeReadPlugin:clearAllMPCache()
    -- Delete each MP book's real directory (which may sit under an old download
    -- root) rather than scanning only the current cache_dir, and only touch
    -- plugin-owned entries tracked in the books table.
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if WeRead.is_mp_book(book_id) then
            os.execute("rm -rf " .. string.format("%q", Content.book_resolved_dir(self.settings, book_id, book)))
            books[book_id] = nil
        end
    end
    self.settings:set("books", books)
    self.settings:flush()
    self:refreshShelfCacheIndicators()
end

function WeReadPlugin:clearAllCache()
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        os.execute("rm -rf " .. string.format("%q", Content.book_resolved_dir(self.settings, book_id, book)))
    end
    self.settings:set("books", {})
    self.settings:flush()
    self:refreshShelfCacheIndicators()
end

function WeReadPlugin:showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function WeReadPlugin:showTransientInfo(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 2,
    })
end

function WeReadPlugin:showBusy(text)
    self:closeBusy()
    self.busy_message = InfoMessage:new{
        text = text,
        dismissable = false,
    }
    UIManager:show(self.busy_message)
    self:refreshUI()
end

function WeReadPlugin:closeBusy()
    if self.busy_message then
        UIManager:close(self.busy_message)
        self.busy_message = nil
        self:refreshUI()
    end
end

function WeReadPlugin:refreshUI()
    if UIManager.forceRePaint then
        local ok, err = pcall(function()
            UIManager:forceRePaint()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "forceRePaint failed:", log_error(err))
        end
    end
end

function WeReadPlugin:showInputDialog(dialog)
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        local ok, err = pcall(function()
            dialog:onShowKeyboard()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "failed to show keyboard:", log_error(err))
        end
    end
end

function WeReadPlugin:isNetworkOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isOnline then
        return true
    end
    local ok_online, online = pcall(function()
        return NetworkMgr:isOnline()
    end)
    if not ok_online then
        logger.warn(LOG_MODULE, "network status check failed:", log_error(online))
        return true
    end
    return online == true
end

function WeReadPlugin:showOffline(label)
    self:closeBusy()
    logger.warn(LOG_MODULE, "network unavailable:", label)
    self:showInfo(T(_("%1 failed:\n%2"), label, _("No network connection. Please connect Wi-Fi and try again.")))
end

function WeReadPlugin:runOnlineTask(label, callback, delay)
    if not self:isNetworkOnline() then
        self:showOffline(label)
        return false
    end
    UIManager:scheduleIn(delay or 0.1, function()
        local ok, err = xpcall(callback, debug.traceback)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "network task failed:", label, log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end)
    return true
end

function WeReadPlugin:runNetworkAction(label, action)
    self:runOnlineTask(label, function()
        local ok, result = pcall(action)
        if ok then
            self:showInfo(result or label)
        else
            logger.err(LOG_MODULE, "network action failed:", label, log_error(result))
            self:showInfo(T(_("%1 failed:\n%2"), label, display_error(result)))
        end
    end)
end

function WeReadPlugin:showList(title, items, empty_text)
    if not items or #items == 0 then
        self:showInfo(empty_text or _("No items."))
        return
    end
    local menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
    return menu
end

function WeReadPlugin:requireLogin(require_cookie, require_api_key)
    local missing_cookie = require_cookie and not self.settings:is_cookie_configured()
    local missing_api_key = require_api_key and not self.settings:is_api_configured()
    if not missing_cookie and not missing_api_key then
        return true
    end
    self:showTransientInfo(_("Please scan the QR code to log in first."), 2)
    UIManager:scheduleIn(0.2, function()
        self.qr_login:start()
    end)
    return false
end

function WeReadPlugin:refreshLoginMenu()
    local menu = self._login_menu_instance
    if menu and type(menu.updateItems) == "function" then
        local ok, err = pcall(function()
            menu:updateItems()
        end)
        if not ok then
            logger.warn(LOG_MODULE, "refresh login menu failed:", log_error(err))
        end
    end
    self:refreshUI()
end

function WeReadPlugin:renewCookieWithUI()
    if not self:requireLogin(true, false) then
        return
    end
    self:runNetworkAction(_("Renew cookie"), function()
        self.client:renew_cookie()
        logger.info(LOG_MODULE, "cookie renewed")
        return _("WeRead cookie renewed.")
    end)
end

function WeReadPlugin:showAccountStatus()
    local account = self.settings:get("account", {})
    local account_name = type(account.name) == "string" and account.name or ""
    if account_name == "" then
        account_name = (self.settings:is_cookie_configured() or self.settings:is_api_configured())
            and _("Unknown account") or _("Not logged in")
    end
    local login_method = account.login_method == "qr" and _("QR login") or _("Unknown")
    local cookie_status = self.settings:is_cookie_configured() and _("configured") or _("missing")
    local api_status = self.settings:is_api_configured() and _("configured") or _("missing")
    self:showInfo(T(
        _("Account: %1\nLogin method: %2\nCookie: %3\nOfficial API key: %4\nCache directory:\n%5"),
        account_name,
        login_method,
        cookie_status,
        api_status,
        BD.dirpath(self.settings.cache_dir)
    ))
end

function WeReadPlugin:confirmClearAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Clear WeRead cookie and API key? Cached books will remain."),
        ok_text = _("Clear"),
        ok_callback = self:safeCallback(_("Clear"), function()
            self.qr_login:cancel()
            self.settings:reset_account()
            self:refreshLoginMenu()
            self:showInfo(_("WeRead account data cleared."))
        end),
    })
end

function WeReadPlugin:getReadReportMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Enable reading time report"),
            checked_func = function()
                return self.settings:get("read_report").enabled
            end,
            callback = self:safeCallback(_("Enable reading time report"), function()
                local cur = self.settings:get("read_report")
                cur.enabled = not cur.enabled
                self.settings:set("read_report", cur)
                self.settings:flush()
                if cur.enabled then
                    if cur.mode == "auto" then
                        self:maybeStartReadReport()
                    elseif cur.book_id == "" then
                        self:showTransientInfo(_("Please select a target book"), 2)
                        self:showReadReportBookPicker()
                    else
                        self:maybeStartReadReport()
                    end
                else
                    self:stopReadReport()
                end
            end),
        },
        {
            text = _("Only report when reading"),
            checked_func = function()
                return self.settings:get("read_report").report_on_open ~= false
            end,
            callback = self:safeCallback(_("Only report when reading"), function()
                local cur = self.settings:get("read_report")
                cur.report_on_open = cur.report_on_open == false
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:stopReadReport("trigger_mode_changed")
                if cur.enabled then
                    self:maybeStartReadReport()
                end
            end),
        },
        {
            text_func = function()
                local current = self.settings:get("read_report")
                if current.mode == "manual" and current.book_title ~= "" then
                    return _("Select target book") .. " · " .. current.book_title
                end
                return _("Select target book")
            end,
            post_text = rr.mode == "auto" and _("Auto-associate") or nil,
            sub_item_table_func = function()
                return self:getReportTargetMenuItems()
            end,
        },
        {
            text = _("Report status"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Report status"), function()
                local cur = self.settings:get("read_report")
                local report_status = self.read_report:status()
                local target
                if cur.mode == "auto" then
                    local auto_title = report_status.target_book_title
                    target = auto_title and T(_("Auto: %1"), auto_title) or _("Auto-associate")
                else
                    target = cur.book_title ~= "" and cur.book_title or _("Not configured")
                end
                local status = report_status.running and _("Running") or _("Stopped")
                local count = report_status.count
                local last = report_status.last_time
                    and os.date("%H:%M:%S", report_status.last_time) or "--"
                local err = report_status.last_error or ""
                local msg = T(_("Report book: %1\nStatus: %2"), target, status)
                    .. "\n" .. T(_("Reported: %1 times, last: %2"), tostring(count), last)
                if err ~= "" then
                    msg = msg .. "\n" .. T(_("Last error: %1"), err)
                end
                self:showInfo(msg)
            end),
        },
    }
end

function WeReadPlugin:getReportTargetMenuItems()
    local rr = self.settings:get("read_report")
    return {
        {
            text = _("Auto-associate with WeRead book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "auto"
            end,
            callback = self:safeCallback(_("Auto-associate with WeRead book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "auto"
                cur.book_id = ""
                cur.book_title = ""
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:stopReadReport("target_changed")
                if cur.enabled then
                    self:maybeStartReadReport()
                end
            end),
        },
        {
            text = _("Manually set report book"),
            checked_func = function()
                return self.settings:get("read_report").mode == "manual"
            end,
            post_text = rr.mode == "manual" and rr.book_title ~= "" and rr.book_title or "",
            callback = self:safeCallback(_("Manually set report book"), function()
                local cur = self.settings:get("read_report")
                cur.mode = "manual"
                self.settings:set("read_report", cur)
                self.settings:flush()
                self:stopReadReport("target_changed")
                self:showReadReportBookPicker()
            end),
        },
    }
end

function WeReadPlugin:detectWeReadBook()
    if not self.ui.document then
        return nil
    end
    local file = self.ui.document.file
    if not file then
        return nil
    end
    local books = self.settings:get("books", {})
    for book_id, book in pairs(books) do
        if type(book) == "table" then
            local dir = Content.book_resolved_dir(self.settings, book_id, book):gsub("/+$", "") .. "/"
            if file == book.cached_file or file:sub(1, #dir) == dir then
                return book_id
            end
        end
    end
    -- Require a path boundary after the cache dir
    local prefix = self.settings.cache_dir:gsub("/+$", "") .. "/"
    if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        local book_id = rest:match("^([^/]+)")
        return book_id
    end
    return nil
end

function WeReadPlugin:showReadReportBookPicker()
    if not self:requireLogin(true, true) then
        return
    end
    self:showBusy(_("Loading bookshelf..."))
    self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/shelf/sync", {})
        end)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "load report bookshelf failed:", log_error(result))
            self:showInfo(T(_("Load bookshelf failed:\n%1"), display_error(result)))
            return
        end
        self:closeBusy()
        local all_books = result.books or {}
        local items = {}
        for i, book in ipairs(all_books) do
            if not WeRead.is_mp_book(book.bookId) then
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    callback = self:safeCallback(book.title or _("Select target book"), function()
                        local rr = self.settings:get("read_report")
                        rr.book_id = book.bookId
                        rr.book_title = book.title or book.bookId
                        self.settings:set("read_report", rr)
                        self.settings:flush()
                        self:stopReadReport("target_changed")
                        if self._picker_menu then
                            UIManager:close(self._picker_menu)
                            self._picker_menu = nil
                        end
                        self:showTransientInfo(T(_("Target book set: %1"), rr.book_title))
                        self:maybeStartReadReport()
                    end),
                })
            end
        end
        if not items or #items == 0 then
            self:showInfo(_("Your WeRead shelf is empty."))
            return
        end
        self._picker_menu = Menu:new{
            title = _("Select a book to report reading time"),
            item_table = items,
            is_borderless = true,
            title_bar_fm_style = true,
        }
        UIManager:show(self._picker_menu)
    end)
end

function WeReadPlugin:showReadStats()
    if not self:requireLogin(false, true) then
        return
    end
    -- Open on the monthly tab by default.
    self:loadReadStats("monthly", nil, nil)
end

-- Fetch reading statistics for a period and (re)show the visualization page.
-- old_view, when provided, is closed once the new data is ready (tab switch or
-- period navigation).
function WeReadPlugin:loadReadStats(mode, base_time, old_view)
    self:showBusy(_("Loading reading statistics..."))
    self:runOnlineTask(_("Reading statistics"), function()
        local ok, data = pcall(function()
            return ReadStats.fetch(self.client, mode, base_time)
        end)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load reading statistics failed:", log_error(data))
            self:showInfo(T(_("%1 failed:\n%2"), _("Reading statistics"), display_error(data)))
            return
        end
        if old_view then
            UIManager:close(old_view)
        end
        local view
        view = ReadStatsView.show(data, {
            on_prev = function()
                self:loadReadStats(mode, data.prev_base_time, view)
            end,
            on_next = function()
                self:loadReadStats(mode, data.next_base_time, view)
            end,
            on_switch = function(new_mode)
                self:loadReadStats(new_mode, nil, view)
            end,
        })
    end)
end

function WeReadPlugin:showBookshelf()
    if not self:requireLogin(true, true) then
        return
    end
    self:showBusy(_("Loading bookshelf..."))
    self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/shelf/sync", {})
        end)
        if not ok then
            self:closeBusy()
            logger.err(LOG_MODULE, "load bookshelf failed:", log_error(result))
            self:showInfo(T(_("Load bookshelf failed:\n%1"), display_error(result)))
            return
        end
        local all_books = result.books or {}
        local shelf = self.settings:get("shelf")
        self.shelf_filters = { reading = shelf.filter_reading, download = shelf.filter_download }
        self.shelf_regular = {}
        self.shelf_mp = {}
        for _i, book in ipairs(all_books) do
            if WeRead.is_mp_book(book.bookId) then
                table.insert(self.shelf_mp, book)
            else
                table.insert(self.shelf_regular, book)
            end
        end
        self.shelf_books = self.shelf_regular
        self:closeBusy()
        if #self.shelf_mp > 0 then
            self:showShelfTabs()
        else
            self:showShelfPage()
        end
    end)
end

local function sortBooks(books, sort_order)
    if sort_order == "default" or not sort_order then
        return books
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return sorted
end

function WeReadPlugin:showShelfPage()
    local books = self.shelf_books or {}
    if #books == 0 then
        self:showInfo(_("Your WeRead shelf is empty."))
        return
    end
    local menu, buildItems
    local function refresh()
        menu:switchItemTable(nil, buildItems())
    end
    buildItems = function()
        local items = self:shelfToolbarItems(true, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        local saved_books = self.settings:get("books", {})
        local downloaded_cache = {}
        self._shelf_saved_books = saved_books
        for _i, book in ipairs(sorted) do
            if self:bookMatchesFilters(book, saved_books, downloaded_cache) then
                local book_id = book.book_id or book.bookId
                local is_cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                local right_text
                if book.readUpdateTime and book.readUpdateTime > 0 then
                    right_text = os.date("%Y-%m-%d", book.readUpdateTime)
                elseif book.finishReading == 1 then
                    right_text = _("Done")
                else
                    right_text = ""
                end
                local function rightStatus(cached)
                    if cached then
                        return right_text ~= "" and "✓  " .. right_text or "✓"
                    end
                    return right_text
                end
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    mandatory = rightStatus(is_cached),
                    mandatory_func = function()
                        local current = self._shelf_saved_books and self._shelf_saved_books[book_id]
                        return rightStatus(current and file_exists(current.cached_file))
                    end,
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        return items
    end
    menu = self:showList(_("WeRead Bookshelf"), buildItems(), _("Your WeRead shelf is empty."))
    self.shelf_menu = menu
    self._shelf_refresh = refresh
end

function WeReadPlugin:refreshShelfCacheIndicators()
    self._shelf_saved_books = self.settings:get("books", {})
    if self.shelf_menu and self._shelf_refresh then
        local ok, err = pcall(self._shelf_refresh)
        if not ok then
            logger.warn(LOG_MODULE, "refresh shelf cache indicators failed:", log_error(err))
        end
    end
end

function WeReadPlugin:showBookRecord(book)
    if not self:requireLogin(true, true) then
        return
    end
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if WeRead.is_mp_book(book_id) then
        self:showMPAccount(book)
        return
    end
    if book_id then
        books[book_id] = books[book_id] or {}
        books[book_id].book_id = book_id
        books[book_id].title = book.title
        books[book_id].author = book.author
        books[book_id].cover = book.cover
        books[book_id].updated_at = os.time()
        self.settings:set("books", books)
        self.settings:flush()
    end
    local saved = books[book_id] or book
    self:showBusy(_("Loading book info..."))
    self:runOnlineTask(_("Book info"), function()
        local ok, err = pcall(function()
            local info = self.client:get_book_info(book_id)
            if info then
                saved.intro = info.intro
                saved.publisher = info.publisher
                saved.isbn = info.isbn
                saved.wordCount = info.wordCount
                saved.newRating = info.newRating
                saved.newRatingCount = info.newRatingCount
                saved.translator = info.translator
                saved.categoryName = info.categoryName or info.category
                books[book_id] = saved
                self.settings:set("books", books)
                self.settings:flush()
            end
            local progress_result = self.client:get_progress(book_id)
            if progress_result and progress_result.book then
                saved.progress = progress_result.book.progress or 0
            end
        end)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load book info failed:", log_error(err))
            self:showInfo(T(_("%1 failed:\n%2"), _("Book info"), display_error(err)))
            return
        end
        self:showBookMenu(saved)
    end)
end

function WeReadPlugin:showBookMenu(book)
    local book_id = book.book_id or book.bookId
    if type(book.chapters) ~= "table" then
        Content.load_catalog_cache(self.client, self.settings, book)
    end
    local menu, buildItems
    local function refresh()
        if menu then
            menu:switchItemTable(nil, buildItems())
        end
    end

    buildItems = function()
        local items = {}

        if book.author and book.author ~= "" then
            table.insert(items, { text = _("Author"), mandatory = book.author })
        end
        if book.translator and book.translator ~= "" then
            table.insert(items, { text = _("Translator"), mandatory = book.translator })
        end
        if book.publisher and book.publisher ~= "" then
            table.insert(items, { text = _("Publisher"), mandatory = book.publisher })
        end
        if book.categoryName and book.categoryName ~= "" then
            table.insert(items, { text = _("Category"), mandatory = book.categoryName })
        end
        if book.wordCount and book.wordCount > 0 then
            local wc = book.wordCount >= 10000
                and string.format("%.1f%s", book.wordCount / 10000, _("w words"))
                or tostring(book.wordCount)
            table.insert(items, { text = _("Word count"), mandatory = wc })
        end
        if book.newRating and book.newRating > 0 then
            local score = string.format("%.1f", book.newRating / 100)
            local count = book.newRatingCount and tostring(book.newRatingCount) or "0"
            table.insert(items, { text = _("Rating"), mandatory = T(_("%1 (%2 ratings)"), score, count) })
        end
        if book.isbn and book.isbn ~= "" then
            table.insert(items, { text = "ISBN", mandatory = book.isbn })
        end
        if book.progress and book.progress > 0 then
            table.insert(items, { text = _("Reading progress"), mandatory = tostring(book.progress) .. "%" })
        end
        if book.intro and book.intro ~= "" then
            table.insert(items, {
                text = _("Introduction"),
                callback = function()
                    UIManager:show(InfoMessage:new{ text = book.intro })
                end,
            })
        end

        if #items > 0 then
            items[#items].separator = true
        end

        local saved_books = self.settings:get("books", {})
        local saved = saved_books[book_id]
        local cached_path = saved and saved.cached_file or book.cached_file
        local is_cached = file_exists(cached_path)
        book.cached_file = is_cached and cached_path or nil

        table.insert(items, {
            text = _("Chapter list"),
            post_text = book.chapters and T(_("%1 chapters"), tostring(#book.chapters)) or _("Not loaded"),
            callback = self:safeCallback(_("Chapter list"), function()
                self:showChapterList(book)
            end),
        })
        if is_cached then
            table.insert(items, {
                text = _("Clear book cache"),
                callback = self:safeCallback(_("Clear book cache"), function()
                    self:confirmClearBookCache(book_id, book.title or book_id, function()
                        book.cached_file = nil
                        book.cached_chapters = nil
                        book.cache_dir = nil
                        book.chapters = nil
                        refresh()
                    end)
                end),
            })
        end
        table.insert(items, {
            text = _("Open cached book"),
            post_text = is_cached and _("Cached") or _("Not cached"),
            enabled_func = function() return is_cached end,
            callback = self:safeCallback(_("Open cached book"), function()
                self:openCachedBook(book)
            end),
        })
        table.insert(items, {
            text = _("Download full book"),
            post_text = _("EPUB"),
            callback = self:safeCallback(_("Download full book"), function()
                self:confirmDownloadAllChapters(book)
            end),
        })
        return items
    end

    menu = self:showList(book.title or _("Book details"), buildItems(), _("No actions."))
end

function WeReadPlugin:showShelfTabs()
    local items = {
        {
            text = _("Books"),
            post_text = T(_("%1 books"), tostring(#self.shelf_regular)),
            callback = self:safeCallback(_("Books"), function()
                self.shelf_books = self.shelf_regular
                self:showShelfPage()
            end),
        },
        {
            text = _("Public Accounts"),
            post_text = T(_("%1 accounts"), tostring(#self.shelf_mp)),
            callback = self:safeCallback(_("Public Accounts"), function()
                self:showMPShelfPage()
            end),
        },
    }
    self:showList(_("WeRead Bookshelf"), items, _("Your WeRead shelf is empty."))
end

function WeReadPlugin:showMPShelfPage()
    local books = self.shelf_mp or {}
    if #books == 0 then
        self:showInfo(_("No items."))
        return
    end
    local menu, buildItems
    local function refresh() menu:switchItemTable(nil, buildItems()) end
    buildItems = function()
        local items = self:shelfToolbarItems(false, refresh)
        local sorted = sortBooks(books, self.settings:get("shelf").sort_order)
        for _i, book in ipairs(sorted) do
            table.insert(items, {
                text = book.title or book.bookId or _("Untitled"),
                post_text = book.author or "",
                callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                    self:showMPAccount(book)
                end),
            })
        end
        return items
    end
    menu = self:showList(_("Public Accounts"), buildItems(), _("No items."))
end

function WeReadPlugin:showMPAccount(book)
    self:rememberMPAccount(book)
    if not self:requireLogin(true, false) then
        return
    end
    local book_id = book.book_id or book.bookId
    local cached = self:getCachedMPArticles(book_id)
    if cached and #cached > 0 then
        self:showMPArticleList(book, cached)
        return
    end
    self:fetchMPArticles(book)
end

function WeReadPlugin:rememberMPAccount(book)
    local book_id = book.book_id or book.bookId
    if not book_id then
        return
    end
    local books = self.settings:get("books", {})
    local record = books[book_id] or {}
    record.book_id = book_id
    record.title = book.title or record.title
    record.author = book.author or record.author
    record.updated_at = os.time()
    -- Keep the resolved cache directory in sync both ways so the transient book
    -- object used for cached-path lookups knows where its articles actually live.
    record.cache_dir = book.cache_dir or record.cache_dir
    book.cache_dir = record.cache_dir
    books[book_id] = record
    self.settings:set("books", books)
    self.settings:flush()
end

function WeReadPlugin:fetchMPArticles(book)
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Loading articles..."), function()
        self:showBusy(_("Loading articles..."))
        local book_id = book.book_id or book.bookId
        local function request_articles()
            local ticket = self.settings:get("wr_ticket", "")
            if ticket == "" then ticket = nil end
            return self.client:get_mp_articles(book_id, 0, 100, ticket)
        end
        local ok, result, err_code = pcall(request_articles)
        if ok and not result and (err_code == -2041 or err_code == -2012) then
            logger.info(LOG_MODULE, "MP credentials rejected; renewing before retry")
            local renew_ok = pcall(function()
                return self.client:renew_cookie()
            end)
            if renew_ok then
                ok, result, err_code = pcall(request_articles)
            end
        end
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load MP articles failed:", log_error(result))
            self:showInfo(T(_("Load articles failed:\n%1"), display_error(result)))
            return
        end
        if not result and (err_code == -2041 or err_code == -2012) then
            logger.warn(LOG_MODULE, "load MP articles rejected, error_code:", tostring(err_code))
            self:showInfo(_("WeRead could not refresh the public-account credential. Please scan the QR code again."))
            return
        end
        if not result then
            logger.warn(LOG_MODULE, "load MP articles failed, error_code:", tostring(err_code))
            self:showInfo(T(_("Load articles failed:\n%1"), "errCode " .. tostring(err_code)))
            return
        end
        local articles = Content.parse_mp_articles(result)
        self:cacheMPArticles(book_id, articles)
        self:showMPArticleList(book, articles)
    end)
end

function WeReadPlugin:getCachedMPArticles(book_id)
    local books = self.settings:get("books", {})
    local record = books[book_id]
    if record and record.mp_articles then
        return record.mp_articles
    end
    return nil
end

function WeReadPlugin:cacheMPArticles(book_id, articles)
    local books = self.settings:get("books", {})
    books[book_id] = books[book_id] or {}
    books[book_id].mp_articles = articles
    books[book_id].mp_articles_time = os.time()
    self.settings:set("books", books)
    self.settings:flush()
end

function WeReadPlugin:showMPArticleList(book, articles)
    local items = {}
    for _i, article in ipairs(articles) do
        local cached_path = Content.mp_article_cached_path(self.settings, book, article)
        local is_cached = cached_path ~= nil
        local date_str = ""
        if article.createTime and article.createTime > 0 then
            date_str = os.date("%Y-%m-%d", article.createTime)
        end
        table.insert(items, {
            text = article.title or _("Article"),
            post_text = date_str,
            mandatory = is_cached and _("Cached") or "",
            callback = self:safeCallback(article.title or _("Article"), function()
                if is_cached then
                    self:openFile(cached_path)
                else
                    self:downloadMPArticleAndRead(book, article)
                end
            end),
        })
    end
    table.insert(items, {
        text = _("Refresh article list"),
        callback = self:safeCallback(_("Refresh article list"), function()
            self:fetchMPArticles(book)
        end),
    })
    self:showList(book.title or _("Public Account"), items, _("No articles."))
end

function WeReadPlugin:downloadMPArticleAndRead(book, article)
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Download article and read"), function()
        self:showBusy(T(_("Downloading article: %1"), article.title or ""))
        local progress_dialog
        local ok, path_or_err = pcall(function()
            return Content.fetch_mp_article_html(self.client, self.settings, book, article, {
                progress = function(current, total)
                    if not progress_dialog then
                        self:closeBusy()
                        progress_dialog = ProgressbarDialog:new{
                            title = T(_("Downloading images: %1"), article.title or ""),
                            progress_max = total,
                        }
                        progress_dialog:show()
                        self:refreshUI()
                    end
                    progress_dialog:reportProgress(current)
                end,
            })
        end)
        if progress_dialog then
            progress_dialog:close()
        else
            self:closeBusy()
        end
        if not ok then
            logger.err(LOG_MODULE, "download MP article failed:", log_error(path_or_err))
            self:showInfo(T(_("Download failed:\n%1"), display_error(path_or_err)))
            return
        end
        logger.info(
            LOG_MODULE,
            "MP article downloaded:",
            "images=", self.settings:get("cache").download_mp_images and "embedded" or "removed"
        )
        -- Persist the resolved cache directory (set by save_mp_article_html) so the
        -- article files can still be located after the download directory changes.
        local book_id = book.book_id or book.bookId
        if book_id and book.cache_dir then
            local books = self.settings:get("books", {})
            local record = books[book_id] or {}
            record.cache_dir = book.cache_dir
            books[book_id] = record
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:openFile(path_or_err)
    end)
end

function WeReadPlugin:loadChapters(book, callback, force_refresh)
    if not force_refresh then
        if book.chapters and #book.chapters > 0 then
            callback(book.chapters)
            return
        end
        local cached = Content.load_catalog_cache(self.client, self.settings, book)
        if cached then
            callback(cached)
            return
        end
    end
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Loading chapter list..."), function()
        self:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            Content.ensure_reader_state(self.client, book)
            return Content.fetch_catalog(self.client, book)
        end)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load chapters failed:", log_error(chapters_or_err))
            self:showInfo(T(_("Load chapters failed:\n%1"), display_error(chapters_or_err)))
            return
        end
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters_or_err)
        if not cache_ok then
            logger.warn(LOG_MODULE, "save chapter catalog cache failed:", log_error(cache_err))
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function WeReadPlugin:showChapterList(book)
    local menu
    local function buildItems(chapters)
        local items = {{
            text = "↻ " .. _("Refresh chapter list"),
            separator = true,
            callback = self:safeCallback(_("Refresh chapter list"), function()
                self:loadChapters(book, function(refreshed_chapters)
                    if menu then
                        menu:switchItemTable(nil, buildItems(refreshed_chapters))
                    end
                    self:showTransientInfo(T(_("Chapter list refreshed: %1 chapters"),
                        tostring(#refreshed_chapters)), 2)
                end, true)
            end),
        }}
        for _i, chapter in ipairs(chapters) do
            local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
            table.insert(items, {
                text = chapter.title or T(_("Chapter %1"), tostring(chapter.chapterUid)),
                post_text = cached and _("Cached") or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    self:openChapter(book, chapter)
                end),
            })
        end
        return items
    end
    self:loadChapters(book, function(chapters)
        menu = self:showList(book.title or _("Chapter list"), buildItems(chapters), _("No chapters."))
    end)
end

function WeReadPlugin:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function WeReadPlugin:openCachedBook(book)
    self:openFile(book.cached_file)
end

-- Open a chapter, preferring its cached file and falling back to a download.
function WeReadPlugin:openChapter(book, chapter)
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
    if cached then
        self:openFile(cached)
    else
        self:downloadChapterAndRead(book, chapter)
    end
end

function WeReadPlugin:downloadChapterAndRead(book, chapter)
    self:confirmAndDownloadChapters(book, { chapter }, "chapter", {
        single_chapter = true,
    })
end

function WeReadPlugin:confirmDownloadAllChapters(book)
    self:loadChapters(book, function(chapters)
        self:confirmAndDownloadChapters(book, chapters, "full", {
            confirmation_text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
        })
    end)
end

-- Show the annotation cost warning consistently for every download entry.
-- With annotations disabled, single/partial downloads start immediately;
-- callers with their own confirmation text (the full-book action) keep only
-- that normal confirmation and do not show the annotation warning.
function WeReadPlugin:confirmAndDownloadChapters(book, chapters, suffix, options)
    options = options or {}
    local includes_annotations = self.settings:get("cache").download_underlines_and_thoughts == true
    local text = options.confirmation_text
    if includes_annotations then
        local warning = _("This download includes underlines and thoughts and may take significantly longer.")
        text = text and (text .. "\n\n" .. warning) or warning
    end
    if not text then
        self.downloader:start(book, chapters, suffix, options)
        return
    end

    local confirm
    confirm = ConfirmBox:new{
        text = text,
        ok_text = _("Download"),
        ok_callback = self:safeCallback(_("Download"), function()
            UIManager:close(confirm)
            self.downloader:start(book, chapters, suffix, options)
        end),
        cancel_text = _("Close"),
    }
    UIManager:show(confirm)
end

function WeReadPlugin:pullProgressWithUI(book_id)
    if not self:requireLogin(true, true) then
        return
    end
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
    end)
end

function WeReadPlugin:showSearch()
    if not self:requireLogin(true, true) then
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Search"), function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchWithUI(keyword)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:searchWithUI(keyword)
    if not keyword or keyword == "" then
        return
    end
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:gateway("/store/search", {
                keyword = keyword,
                count = 10,
            })
        end)
        if not ok then
            logger.err(LOG_MODULE, "search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local items = {}
        for group_index, group in ipairs(result.results or {}) do
            for book_index, entry in ipairs(group.books or {}) do
                local book = entry.bookInfo or entry
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    mandatory = book.category or "",
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        self:showList(T(_("Search: %1"), keyword), items, _("No search results."))
    end)
end

function WeReadPlugin:showPasteReaderURL()
    local dialog
    dialog = InputDialog:new{
        title = _("Paste WeRead reader URL"),
        input = "https://weread.qq.com/web/reader/",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Parse"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Parse"), function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        self:parseReaderURLWithUI(url)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:parseReaderURLWithUI(url)
    if not self:requireLogin(true, false) then
        return
    end
    self:runNetworkAction(_("Parse reader URL"), function()
        local html = self.client:get_text(url, { referer = url })
        local book_id = html:match([["bookId"%s*:%s*"([^"]+)"]]) or html:match([["bookId"%s*:%s*(%d+)]])
        local title = html:match([["title"%s*:%s*"([^"]+)"]]) or _("Unknown title")
        local psvts = html:match([["psvts"%s*:%s*"([^"]+)"]])
        local pclts = html:match([["pclts"%s*:%s*"([^"]+)"]])
        local token = html:match([["token"%s*:%s*"([^"]+)"]])
        if not book_id then
            return _("Reader HTML loaded, but bookId was not found.")
        end
        local books = self.settings:get("books", {})
        local record = books[book_id] or {}
        record.book_id = book_id
        record.title = title
        record.reader_url = url
        record.psvts = psvts
        record.pclts = pclts
        record.token = token
        record.updated_at = os.time()
        books[book_id] = record
        self.settings:set("books", books)
        self.settings:flush()
        return T(_("Reader URL parsed.\nBook: %1\nbookId: %2"), title, book_id)
    end)
end


function WeReadPlugin:showCurrentBookDetails()
    if not self:requireLogin(true, true) then
        return
    end
    local book_id = self:detectWeReadBook()
    local book = book_id and self.settings:get("books", {})[book_id] or nil
    if not book then
        self:showInfo(_("The current document is not a WeRead cached book."))
        return
    end
    book.book_id = book.book_id or book_id
    self:showBookRecord(book)
end

function WeReadPlugin:onShowWeRead()
    self:showAccountStatus()
end

function WeReadPlugin:onWeReadSyncProgress()
    if not self:requireLogin(true, false) then
        return
    end
    local books = self.settings:get("books", {})
    local book_id, book
    for id, item in pairs(books) do
        book_id, book = id, item
        break
    end
    if not book_id then
        self:showInfo(_("Parse a WeRead reader URL before testing progress sync."))
        return
    end
    local payload = WeRead.make_read_payload{
        book_id = book_id,
        chapter_uid = book.chapter_uid or 0,
        chapter_idx = book.chapter_idx or 0,
        chapter_offset = book.chapter_offset or 0,
        progress = book.progress or 0,
        summary = book.summary or "",
        app_id = book.app_id,
        psvts = book.psvts,
        pclts = book.pclts,
        token = book.token,
    }
    UIManager:show(ConfirmBox:new{
        text = T(_("Upload local progress to WeRead?\n\nBook: %1\nProgress: %2%%\nChapter offset: %3"), book.title or book_id, tostring(payload.pr), tostring(payload.co)),
        ok_text = _("Upload"),
        ok_callback = self:safeCallback(_("Upload"), function()
            self:runNetworkAction(_("Sync progress"), function()
                local result = self.client:report_read(payload, book.reader_url)
                if result and result.succ then
                    return _("WeRead progress synced.")
                end
                return _("Progress request sent, but response did not include succ=1.")
            end)
        end),
    })
end

-- Runtime CSS that hides underlines and thought stars baked into cached EPUBs.
-- Applied as an appended stylesheet (not persisted to the book sidecar) so it
-- acts as a global display preference without mutating downloaded files.
-- NOTE: only tweak visual/metric properties (border, padding, font-size). Never
-- use display/white-space here — changing those marks the built DOM stale and
-- makes ReaderRolling repeatedly prompt for a full document reload.
local ANNOTATION_HIDE_CSS =
    ".wr-underline{border-bottom:0 !important;padding-bottom:0 !important;} .wr-star{font-size:0 !important;} "
    .. ".wr-thought-link{pointer-events:none !important;text-decoration:none !important;color:inherit !important;}"

-- Apply the initial hidden state before KOReader renders the document. Doing
-- this from onReaderReady starts partial rerendering; its seamless reload then
-- creates a new plugin instance and repeats the same rerender forever.
function WeReadPlugin:onReadSettings()
    if not self.ui or not self.ui.document or not self:detectWeReadBook() then
        return
    end
    if self.settings:get("cache").show_annotations ~= false then
        return
    end
    local typeset = self.ui.typeset
    if not typeset or not typeset.css then
        logger.warn(LOG_MODULE, "onReadSettings: typeset stylesheet unavailable")
        return
    end
    local tweaks = ""
    local styletweak = self.ui.styletweak
    if styletweak and type(styletweak.getCssText) == "function" then
        tweaks = styletweak:getCssText() or ""
    end
    local ok, err = pcall(function()
        self.ui.document:setStyleSheet(typeset.css, tweaks .. "\n" .. ANNOTATION_HIDE_CSS)
    end)
    if not ok then
        logger.warn(LOG_MODULE, "initial annotation visibility failed:", err)
    end
end

-- Reapply the current annotation visibility preference to the open WeRead book.
-- Show=true reapplies the base stylesheet + user tweaks (revealing baked-in
-- underlines); show=false appends ANNOTATION_HIDE_CSS on top. Triggers a reflow.
function WeReadPlugin:applyAnnotationVisibility()
    if not self.ui or not self.ui.document then
        return
    end
    if not self:detectWeReadBook() then
        return
    end
    local typeset = self.ui.typeset
    if not typeset or not typeset.css then
        logger.warn(LOG_MODULE, "applyAnnotationVisibility: typeset stylesheet unavailable")
        return
    end
    local show = self.settings:get("cache").show_annotations ~= false
    local tweaks = ""
    local styletweak = self.ui.styletweak
    if styletweak and type(styletweak.getCssText) == "function" then
        tweaks = styletweak:getCssText() or ""
    end
    if not show then
        tweaks = tweaks .. "\n" .. ANNOTATION_HIDE_CSS
    end
    local ok, err = pcall(function()
        self.ui.document:setStyleSheet(typeset.css, tweaks)
        self.ui:handleEvent(Event:new("UpdatePos"))
    end)
    if not ok then
        logger.warn(LOG_MODULE, "applyAnnotationVisibility failed:", err)
    end
end

-- True when the tap falls in the configured left/right page-turn edge zone.
-- Honours cache.ignore_edge_thought_taps and cache.edge_tap_ratio.
local function isPageTurnEdgeTap(plugin, ges)
    if not plugin or not ges or not ges.pos then
        return false
    end
    local cache = plugin.settings:get("cache")
    if cache.ignore_edge_thought_taps == false then
        return false
    end
    local ratio = tonumber(cache.edge_tap_ratio) or 0.20
    if ratio < 0.05 then
        ratio = 0.05
    elseif ratio > 0.45 then
        ratio = 0.45
    end
    local Screen = require("device").screen
    local x = ges.pos.x
    local w = Screen:getWidth()
    local edge = w * ratio
    return x < edge or x > (w - edge)
end

-- Hide our thought anchors from KOReader's link hit-testing when:
--   1) annotations are hidden, or
--   2) edge-tap ignore is on and the tap is in the left/right page-turn zone.
--
-- crengine ignores CSS pointer-events for link detection, so without this a tap
-- on a thought underline is swallowed by ReaderLink (it follows the #wrthought
-- anchor — a same-page jump / native link popup showing the underlined text)
-- instead of turning the page.
--
-- Wrap onTap itself and return false for ignored thoughts,
-- so the event continues to propagate to the page-turn zone (honoring the user's
-- tap zones / RTL). Only own anchors are affected.
function WeReadPlugin:_installLinkFilter()
    if not self.ui or not self.ui.link or self._orig_getLinkFromGes then
        return
    end

    local plugin = self

    -- 1) Filter getLinkFromGes (covers the simple / no-larger-area path)
    self._orig_getLinkFromGes = self.ui.link.getLinkFromGes
    self.ui.link.getLinkFromGes = function(link_self, ges)
        local link = plugin._orig_getLinkFromGes(link_self, ges)
        if not link then
            return nil
        end
        local href = plugin:_linkHref(link)
        if type(href) ~= "string" or not href:find("wrthought%-") then
            return link
        end
        if plugin.settings:get("cache").show_annotations == false
            or isPageTurnEdgeTap(plugin, ges) then
            return nil
        end
        return link
    end

    -- 2) Also wrap onTap so the larger-area / onGoToPageLink path is skipped
    if not self._orig_onTap then
        self._orig_onTap = self.ui.link.onTap
        self.ui.link.onTap = function(link_self, arg, ges)
            -- When we want to ignore thoughts (edge zone or annotations hidden),
            -- detect the link with the *original* getter and suppress only own #wrthought anchors.
            if plugin.settings:get("cache").show_annotations == false
                or isPageTurnEdgeTap(plugin, ges) then
                local link = plugin._orig_getLinkFromGes(link_self, ges)
                if link then
                    local href = plugin:_linkHref(link)
                    if type(href) == "string" and href:find("wrthought%-") then
                        return false
                    end
                end
            end
            return plugin._orig_onTap(link_self, arg, ges)
        end
    end
end

function WeReadPlugin:_removeLinkFilter()
    if self.ui and self.ui.link then
        if self._orig_getLinkFromGes then
            self.ui.link.getLinkFromGes = self._orig_getLinkFromGes
        end
        if self._orig_onTap then
            self.ui.link.onTap = self._orig_onTap
        end
    end
    self._orig_getLinkFromGes = nil
    self._orig_onTap = nil
end

function WeReadPlugin:_teardownThoughtInterception()
    if self._thought_interception_setup and self.ui then
        self.ui:unRegisterTouchZones({
            { id = "weread_thought_tap", overrides = { "tap_link" } },
        })
        self._thought_interception_setup = nil
    end
    self:_removeLinkFilter()
    ThoughtPopup.closeVisible()
    ThoughtPopup.cancelPrewarm()
    self._thought_popup_open = nil
    self._current_thought_popup = nil
    self._thought_html_cache = nil
    self._thought_html_cache_n = nil
    self._thought_json_cache = nil
    self._thought_json_cache_n = nil
    self._thought_highlight_active = nil
    self._current_weread_book_id = nil
end

function WeReadPlugin:_setupThoughtInterception()
    local Device = require("device")
    if not Device:isTouchDevice() then
        return
    end
    if not self.ui or self._thought_interception_setup then
        return
    end

    self.ui:registerTouchZones({
        {
            id = "weread_thought_tap",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "tap_link" },
            handler = function(ges)
                return self:_onThoughtTap(ges)
            end,
        },
    })
    self:_installLinkFilter()
    self._thought_interception_setup = true
end

function WeReadPlugin:_clearThoughtHighlight(document)
    if not self._thought_highlight_active then
        return
    end
    pcall(function()
        document:highlightXPointer()
    end)
    self._thought_highlight_active = nil
    UIManager:setDirty(self.dialog, "ui")
end

function WeReadPlugin:_getThoughtPopupLayoutParams()
    if not self.ui or not self.ui.document then
        return nil
    end

    local Screen = require("device").screen
    local document = self.ui.document

    local font_face = self.ui.font and self.ui.font.font_face
    if not font_face then
        font_face = G_reader_settings:readSetting("cre_font")
    end

    local font_size = G_reader_settings:readSetting("footnote_popup_absolute_font_size")
    local font_size_scaled
    if font_size then
        font_size_scaled = Screen:scaleBySize(font_size)
    else
        local relative = G_reader_settings:readSetting("footnote_popup_relative_font_size") or -2
        local doc_font_size = (document.configurable and document.configurable.font_size) or 18
        font_size_scaled = Screen:scaleBySize(doc_font_size) + relative
    end

    return {
        doc_font_name = font_face,
        doc_font_size = font_size_scaled,
        doc_margins = document:getPageMargins(),
        height_ratio = 0.35,
    }
end

function WeReadPlugin:_showThoughtPopup(html, link, session_gen, tap_started)
    local show_started = time.now()
    if session_gen and session_gen ~= self._reader_session_gen then
        self._thought_popup_open = nil
        return
    end
    if type(html) ~= "string" or html == "" then
        self._thought_popup_open = nil
        return
    end

    local Screen = require("device").screen
    local document = self.ui.document
    if link.from_xpointer then
        local highlight_started = time.now()
        local ok = pcall(function()
            document:highlightXPointer()
            document:highlightXPointer(link.from_xpointer)
        end)
        thought_perf("highlight", highlight_started, "ok=", tostring(ok))
        if ok then
            self._thought_highlight_active = true
            UIManager:setDirty(self.dialog, "partial")
        end
    end

    local params_started = time.now()
    local params = self:_getThoughtPopupLayoutParams()
    thought_perf("layout_params", params_started)
    if not params then
        self._thought_popup_open = nil
        return
    end

    local fonts_started = time.now()
    ThoughtPopup.preloadFonts(params.doc_font_name)
    thought_perf("preload_fonts", fonts_started)

    local popup_started = time.now()
    local ok, popup = pcall(function()
        return ThoughtPopup.show({
            html = html,
            doc_font_name = params.doc_font_name,
            doc_font_size = params.doc_font_size,
            doc_margins = params.doc_margins,
            height_ratio = params.height_ratio,
            dialog = self.dialog,
            close_callback = function(footnote_height)
                self._thought_popup_open = nil
                self._current_thought_popup = nil
                if self._thought_highlight_active then
                    local highlight_page = document:getCurrentPage()
                    local clear_gen = self._reader_session_gen or 0
                    local clear_highlight = function()
                        if clear_gen ~= self._reader_session_gen then
                            return
                        end
                        document:highlightXPointer()
                        if document:getCurrentPage() == highlight_page then
                            UIManager:setDirty(self.dialog, "ui")
                        end
                    end
                    self._thought_highlight_active = nil
                    local footnote_top_y = Screen:getHeight() - footnote_height
                    if link.link_y and link.link_y > footnote_top_y then
                        UIManager:scheduleIn(0.5, clear_highlight)
                    else
                        clear_highlight()
                    end
                end
            end,
        })
    end)
    thought_perf("popup_show", popup_started, "ok=", tostring(ok),
        "html_bytes=", tostring(#html))

    if not ok then
        logger.warn(LOG_MODULE, "thought popup failed:", popup)
        self._thought_popup_open = nil
        self:_clearThoughtHighlight(document)
        return
    end

    self._current_thought_popup = popup
    thought_perf("show_pipeline", show_started, "html_bytes=", tostring(#html))
    if tap_started then
        thought_perf("tap_to_popup_return", tap_started, "html_bytes=", tostring(#html))
    end
end

-- Recursively pull a thought anchor href out of a KOReader link object.
-- The link's shape differs between engines and even between tap locations inside
-- the same anchor (tapping the star vs the underlined text can expose the href
-- under a different field), so scan common fields first, then a shallow crawl.
function WeReadPlugin:_linkHref(link)
    local seen = {}
    local function extract(value, depth)
        if depth > 4 or value == nil then
            return nil
        end
        if type(value) == "string" then
            return value:match("(#wrthought%-[%w%._%-]+)")
                or value:match("(wrthought%-[%w%._%-]+)")
        end
        if type(value) ~= "table" or seen[value] then
            return nil
        end
        seen[value] = true
        for _, key in ipairs({ "href", "url", "target", "link", "uri", "dest", "destination", "src" }) do
            local found = extract(value[key], depth + 1)
            if found then
                return found
            end
        end
        for _, child in pairs(value) do
            local found = extract(child, depth + 1)
            if found then
                return found
            end
        end
        return nil
    end
    return extract(link, 0)
end

-- Parse "#wrthought-<book>-<chapter>-<start>-<end>" into its parts. The last two
-- segments are numeric (range start/end); book/chapter must not contain dashes
-- (true for WeRead IDs in practice).
function WeReadPlugin:_parseThoughtHref(href)
    if type(href) ~= "string" then
        return nil
    end
    local anchor = href:match("#?(wrthought%-[%w%._%-]+)")
    if not anchor then
        return nil
    end
    local book_id, chapter_uid, start_pos, end_pos =
        anchor:match("^wrthought%-([^%-]+)%-([^%-]+)%-(%d+)%-(%d+)$")
    if not (book_id and chapter_uid and start_pos and end_pos) then
        logger.warn(LOG_MODULE, "unparseable thought anchor:", anchor)
        return nil
    end
    return {
        book_id = book_id,
        chapter_uid = chapter_uid,
        range = start_pos .. "-" .. end_pos,
    }
end

-- Load a chapter's cached thoughts, memoized per (book, chapter) so tapping
-- different underlines in the same chapter reads/decodes the JSON only once.
-- Returns the decoded reviews array, or false if the chapter has no cache.
function WeReadPlugin:_loadThoughtReviews(book_id, chapter_uid)
    self._thought_json_cache = self._thought_json_cache or {}
    local key = tostring(book_id) .. ":" .. tostring(chapter_uid)
    local cached = self._thought_json_cache[key]
    if cached ~= nil then
        return cached
    end
    local reviews = Thoughts.load_cache(self.settings, book_id, chapter_uid)
    if type(reviews) ~= "table" then
        reviews = false
    end
    self._thought_json_cache_n = (self._thought_json_cache_n or 0) + 1
    if self._thought_json_cache_n > THOUGHT_JSON_CACHE_MAX then
        self._thought_json_cache = {}
        self._thought_json_cache_n = 1
    end
    self._thought_json_cache[key] = reviews
    return reviews
end

-- Whether this href's chapter thoughts are already decoded in memory. Used to
-- decide if the first-tap loading message is needed (skipped once cached).
function WeReadPlugin:_isChapterThoughtsCached(href)
    local info = self:_parseThoughtHref(href)
    if not info or not self._thought_json_cache then
        return false
    end
    return self._thought_json_cache[tostring(info.book_id) .. ":" .. tostring(info.chapter_uid)] ~= nil
end

-- Load the chapter's cached thoughts, match the tapped range, render popup HTML.
function WeReadPlugin:_buildThoughtHtmlFromHref(href)
    local info = self:_parseThoughtHref(href)
    if not info then
        return nil
    end
    local reviews = self:_loadThoughtReviews(info.book_id, info.chapter_uid)
    if type(reviews) ~= "table" then
        -- Cache missing/unreadable (e.g. user deleted thoughts/<uid>.json).
        self:showInfo(_("No cached thoughts found for this chapter. Please re-download the book with underlines and thoughts."))
        return nil
    end
    for _i, rv in ipairs(reviews) do
        if tostring(rv.range or "") == info.range then
            local html = Annotations.buildThoughtPopupHtml(rv)
            if type(html) == "string" and html ~= "" then
                return html
            end
            break
        end
    end
    -- Recognized underline but no renderable thought (range not in cache, or empty).
    self:showInfo(_("No matching thought found for this underline."))
    return nil
end

function WeReadPlugin:_onThoughtTap(ges)
    local tap_started = time.now()
    if not self.ui or not self.ui.document or not self.ui.link then
        return false
    end
    -- The tap zone is only registered for WeRead books, so a cached flag is
    -- enough here; avoid re-scanning the book table on every tap.
    if not self._current_weread_book_id then
        return false
    end

    -- Edge taps are for page turns — never intercept them for thoughts.
    -- The link filter also hides our anchors here so native link UI does not fire.
    if isPageTurnEdgeTap(self, ges) then
        return false
    end

    local link_started = time.now()
    local ok, link = pcall(function()
        return self.ui.link:getLinkFromGes(ges)
    end)
    thought_perf("link_lookup", link_started, "found=", tostring(ok and link ~= nil))
    -- No followable link here (e.g. hidden underline whose link is disabled via
    -- pointer-events:none) → return false so the tap falls through to KOReader's
    -- default page-turn, honoring the user's tap-zone / RTL settings.
    if not ok or not link then
        return false
    end

    local href = self:_linkHref(link)
    if type(href) ~= "string" or not href:find("wrthought%-") then
        -- Some other EPUB link (footnote, TOC, external) → let KOReader handle it.
        return false
    end

    -- Annotations hidden: _installLinkFilter already made getLinkFromGes return nil
    -- for our anchors, so we normally return above before reaching here. Kept as a
    -- defensive fall-through in case the filter is not active.
    if self.settings:get("cache").show_annotations == false then
        return false
    end

    -- Cache the rendered HTML by href (stable, page-independent).
    self._thought_html_cache = self._thought_html_cache or {}
    local html = self._thought_html_cache[href]
    if html == nil then
        -- The first tap in a chapter reads + decodes its thoughts JSON, which can
        -- take a moment for chapters with many thoughts. Show a brief loading
        -- message; skipped once the chapter is cached, so it never flashes on
        -- subsequent (instant) taps.
        local loading
        if not self:_isChapterThoughtsCached(href) then
            loading = InfoMessage:new{ text = _("Loading thoughts…") }
            UIManager:show(loading)
            self:refreshUI()  -- force the message to paint before the blocking load
        end
        html = self:_buildThoughtHtmlFromHref(href) or false
        if loading then
            UIManager:close(loading)
        end
        self._thought_html_cache_n = (self._thought_html_cache_n or 0) + 1
        if self._thought_html_cache_n > THOUGHT_HTML_CACHE_MAX then
            self._thought_html_cache = {}
            self._thought_html_cache_n = 1
        end
        self._thought_html_cache[href] = html
    end
    thought_perf("tap_resolve", tap_started, "cached=", tostring(html ~= nil),
        "html_bytes=", tostring(type(html) == "string" and #html or 0))
    if html == false or type(html) ~= "string" then
        -- Recognized our underline but have no content (already told the user why,
        -- e.g. deleted cache). Consume the tap so tap_link does not follow the
        -- now-pointless #wrthought anchor.
        return true
    end

    -- Guard against a stale flag: if we believe a popup is open but it is not
    -- actually on screen (e.g. it was closed through a path that skipped the
    -- close callback), reset instead of silently swallowing every tap forever.
    if self._thought_popup_open then
        if ThoughtPopup.isShowing() then
            return true
        end
        self._thought_popup_open = nil
    end
    self._thought_popup_open = true
    local session_gen = self._reader_session_gen or 0
    local scheduled_at = time.now()
    UIManager:nextTick(function()
        thought_perf("next_tick_delay", scheduled_at)
        if session_gen ~= self._reader_session_gen then
            self._thought_popup_open = nil
            return
        end
        if not self.ui or not self.ui.document then
            self._thought_popup_open = nil
            return
        end
        self:_showThoughtPopup(html, link, session_gen, tap_started)
    end)
    return true
end

-- Intercepts ReaderStatus:onEndOfBook for WeRead books (installed as a hook in
-- onReaderReady). Non-WeRead books defer to the original handler. For WeRead
-- books, an end_document_action of "next_file" auto-advances to the next
-- chapter; every other action (pop-up, book_status, …) shows our own navigation
-- dialog instead of the native one, falling back to the native handler only
-- when the dialog cannot be built.
function WeReadPlugin:handleEndOfBook(status_self)
    local action = G_reader_settings and G_reader_settings:readSetting("end_document_action") or "pop-up"
    local book_id = self:detectWeReadBook()
    if not book_id then
        return self._orig_onEndOfBook(status_self)
    end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    self:ensureChaptersLoaded(book)
    local file = self.ui.document and self.ui.document.file
    local current_idx, current_ch, is_full_book = self:getChapterInfoFromFile(book, file)
    local next_ch = (not is_full_book) and current_idx and book.chapters[current_idx + 1]

    if action == "next_file" then
        if next_ch then
            self:openChapter(book, next_ch)
        else
            self:showInfo(_("You have reached the last chapter."))
        end
        return true
    end

    -- For every other end-of-document action, prefer our WeRead navigation
    -- dialog. This intentionally overrides the global end_document_action
    -- (pop-up, book_status, …) for WeRead books; fall back to the native
    -- handler only when the dialog cannot be built.
    if self:showEndOfBookDialog(book_id) then
        return true
    end

    return self._orig_onEndOfBook(status_self)
end

function WeReadPlugin:onReaderReady()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()

    local weread_book_id = self:detectWeReadBook()
    -- Cache it so the per-tap handler (_onThoughtTap) does not have to re-scan
    -- the whole book table on every screen tap.
    self._current_weread_book_id = weread_book_id
    if weread_book_id then
        -- Always register the tap interception: even when annotations are hidden
        -- we must intercept taps on thought links to suppress the native footnote
        -- popup. Visibility is decided inside _onThoughtTap / applyAnnotationVisibility.
        self:_setupThoughtInterception()
        local show_annotations = self.settings:get("cache").show_annotations ~= false
        UIManager:nextTick(function()
            if not self.ui or not self.ui.document then
                return
            end
            if not show_annotations then
                return
            end
            local params = self:_getThoughtPopupLayoutParams()
            if not params then
                return
            end
            ThoughtPopup.preloadFonts(params.doc_font_name)
            ThoughtPopup.prewarm({
                doc_font_name = params.doc_font_name,
                doc_font_size = params.doc_font_size,
                doc_margins = params.doc_margins,
                height_ratio = params.height_ratio,
                dialog = self.dialog,
            })
        end)

        if not self._orig_onEndOfBook and self.ui.status and type(self.ui.status.onEndOfBook) == "function" then
            self._orig_onEndOfBook = self.ui.status.onEndOfBook
            self.ui.status.onEndOfBook = function(status_self)
                return self:handleEndOfBook(status_self)
            end
        end
    else
        if self._orig_onEndOfBook and self.ui.status then
            self.ui.status.onEndOfBook = self._orig_onEndOfBook
            self._orig_onEndOfBook = nil
        end
    end

    local _started, _title, reason = self.read_report:on_reader_ready()
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "auto" and reason == "document_not_weread" then
        self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
    end
end

function WeReadPlugin:onCloseDocument()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()

    if self._orig_onEndOfBook and self.ui.status then
        self.ui.status.onEndOfBook = self._orig_onEndOfBook
        self._orig_onEndOfBook = nil
    end

    self.read_report:on_close_document()
end

function WeReadPlugin:maybeStartReadReport()
    return self.read_report:maybe_start("menu")
end

function WeReadPlugin:stopReadReport(reason)
    self.read_report:stop(reason or "explicit_stop")
end

function WeReadPlugin:onSuspend()
    self.read_report:on_suspend()
end

function WeReadPlugin:onResume()
    self.read_report:on_resume()
end

-- Returns true if the custom dialog was successfully displayed, or false if
-- the dialog could not be built (e.g., missing chapter info for MP articles),
-- allowing the caller to fall back to the native end-of-book handler.
function WeReadPlugin:showEndOfBookDialog(book_id)
    local file_path = self.ui.document and self.ui.document.file
    if not file_path then return false end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    if not book or not self:ensureChaptersLoaded(book) then return false end

    local current_idx, current_ch, is_full_book = self:getChapterInfoFromFile(book, file_path)
    -- The chapter-nav row is shown only for single downloaded chapters (a mapped
    -- current chapter that is not part of a full-book EPUB); "next chapter"
    -- additionally requires a successor.
    local show_chapter_nav = current_idx ~= nil and not is_full_book
    local next_chapter = show_chapter_nav and book.chapters[current_idx + 1] or nil

    EndOfBookDialog.show({ show_chapter_nav = show_chapter_nav, has_next = next_chapter ~= nil }, {
        on_bookshelf = function()
            self:showBookshelf()
        end,
        on_search = function()
            self:showSearch()
        end,
        on_chapter_list = function()
            self:showChapterList(book)
        end,
        on_next = next_chapter and function()
            self:openChapter(book, next_chapter)
        end or nil,
        on_book_details = function()
            self:showCurrentBookDetails()
        end,
        on_read_stats = function()
            self:showReadStats()
        end,
        on_close_book = function()
            -- Mirror KOReader's ReaderStatus:openFileBrowser(): closing the
            -- reader alone exits the app when there is no file-manager stack, so
            -- reopen the file browser right after (positioned on the book file).
            local ui = self.ui
            if not ui then return end
            local file = ui.document and ui.document.file
            ui:onClose()
            if file and ui.showFileManager then
                ui:showFileManager(file)
            end
        end,
    })
    return true
end

-- Ensure the book's chapter catalog is available in memory. Since chapter lists
-- are no longer persisted with the book record (they live in a separate on-disk
-- catalog cache), a book loaded from settings usually has book.chapters == nil;
-- this loads it from the cache. Synchronous, no network. Returns the chapter
-- list, or nil if the cache is missing (e.g. the book was never opened/cached).
function WeReadPlugin:ensureChaptersLoaded(book)
    if not book then return nil end
    if not (type(book.chapters) == "table" and #book.chapters > 0) then
        Content.load_catalog_cache(self.client, self.settings, book)
    end
    return book.chapters
end

-- Retrieves chapter information for the given file path.
--
-- Parameters:
--   book: The book object from settings containing chapters and cached_chapters.
--   file_path: The absolute path of the currently open document.
--
-- Returns:
--   current_idx (number or nil): The index of the current chapter within book.chapters, if it's a single chapter file.
--   current_ch (table or nil): The chapter object of the current chapter, if it's a single chapter file.
--   is_full_book (boolean): True if the file maps to multiple chapters (e.g. a combined EPUB), false otherwise.
function WeReadPlugin:getChapterInfoFromFile(book, file_path)
    if not book or not file_path or not book.chapters or not book.cached_chapters then
        return nil, nil, false
    end

    local mapped_count = 0
    local current_uid = nil
    for uid, path in pairs(book.cached_chapters) do
        if path == file_path then
            mapped_count = mapped_count + 1
            current_uid = uid
        end
    end

    local is_full_book = (mapped_count > 1)

    if mapped_count == 1 and current_uid then
        for i, ch in ipairs(book.chapters) do
            if tostring(ch.chapterUid) == tostring(current_uid) then
                return i, ch, is_full_book
            end
        end
    end

    return nil, nil, is_full_book
end

function WeReadPlugin:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return WeReadPlugin
