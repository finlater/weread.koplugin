local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local DownloadDialog = require("lib.download_dialog")
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

local Cookie = require("lib.cookie")
local Client = require("lib.client")
local Content = require("lib.content")
local Crypto = require("lib.crypto")
local I18n = require("lib.i18n")
local Settings = require("lib.settings")
local Thoughts = require("lib.thoughts")
local WeRead = require("lib.weread")
local ThoughtPopup = require("lib.thought_popup")

-- `_` is the translation function; never reuse it as a loop placeholder in this file.
local function _(text)
    return I18n.tr(text)
end

local LOG_MODULE = "[WeRead]"
local unpack_args = unpack or table.unpack

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

local function config_auth_fingerprint(config)
    local parts = {}
    for _, key in ipairs({ "curl", "cookie", "mp_curl", "wr_ticket", "wr_wrpa" }) do
        local value = type(config[key]) == "string" and config[key] or ""
        table.insert(parts, key .. ":" .. tostring(#value) .. ":" .. value)
    end
    return Crypto.sha256_hex(table.concat(parts, "\n"))
end

local function stable_config_value(value)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    local keys = {}
    for key in pairs(value) do
        table.insert(keys, tostring(key))
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, key .. "=" .. stable_config_value(value[key]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function config_preferences_fingerprint(config)
    local preferences = {
        sync = config.sync,
        cache = config.cache,
        read_report = config.read_report,
        shelf = config.shelf,
    }
    return Crypto.sha256_hex(stable_config_value(preferences))
end

local function merge_cookie_tables(current, updates)
    current = current or {}
    for key, value in pairs(updates or {}) do
        current[key] = value
    end
    return current
end

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = "0.1.1",
}

local function plugin_dir()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    return path:match("^(.*)/[^/]+$") or "."
end

function WeReadPlugin:init()
    math.randomseed(os.time())
    self.plugin_dir = plugin_dir()
    self.settings = Settings:new()
    self.client = Client:new(self.settings)
    self:loadConfigFile("startup")
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "manual" and rr.book_id ~= "" and not rr.report_on_open then
        self:startReadReport(true)
    end
    ThoughtPopup.init()
    self._reader_session_gen = 0
    logger.info(LOG_MODULE, "initialized:", "version=", self.version)
end

function WeReadPlugin:loadConfigFile(source)
    source = source or "unknown"
    self._config_error = nil
    local config_path = (self.plugin_dir or plugin_dir()) .. "/config.lua"
    local file = io.open(config_path, "r")
    if not file then
        logger.info(LOG_MODULE, "config.lua not found; using stored settings:", "source=", source)
        return
    end
    file:close()

    local ok, config = pcall(dofile, config_path)
    if not ok then
        self._config_error = tostring(config)
        logger.warn(LOG_MODULE, "config.lua load failed:", "source=", source, log_error(config))
        return
    end
    local preferences_fingerprint = config_preferences_fingerprint(config)
    local stored_preferences_fingerprint = self.settings:get("config_preferences_fingerprint", "")
    local apply_preferences = source == "manual_reload"
        or preferences_fingerprint ~= stored_preferences_fingerprint
    local applied, err = self.settings:apply_config(config, {
        apply_preferences = apply_preferences,
    })
    if not applied then
        self._config_error = err
        logger.warn(LOG_MODULE, "config.lua apply failed:", "source=", source, log_error(err))
        return
    end
    if apply_preferences then
        self.settings:set("config_preferences_fingerprint", preferences_fingerprint)
        logger.info(LOG_MODULE, "config preferences imported:", "source=", source)
    else
        logger.info(LOG_MODULE, "config preferences unchanged; using persisted settings")
    end

    local fingerprint = config_auth_fingerprint(config)
    local stored_fingerprint = self.settings:get("config_auth_fingerprint", "")
    local import_auth = source == "manual_reload" or fingerprint ~= stored_fingerprint
    if import_auth then
        local raw_cookie = ""
        local curl_payload
        local imported_cookies = self.settings:get("cookies", {})
        if type(config.curl) == "string" and config.curl:match("%S") then
            raw_cookie, curl_payload = Cookie.extract_from_curl(config.curl)
        elseif type(config.cookie) == "string" and config.cookie:match("%S") then
            raw_cookie = config.cookie
        end

        if raw_cookie and raw_cookie:match("%S") then
            local cookies = Cookie.parse_cookie_header(raw_cookie)
            if Cookie.has_login_cookie(cookies) then
                imported_cookies = merge_cookie_tables(imported_cookies, cookies)
            end
        end

        local mp_source = type(config.mp_curl) == "string" and config.mp_curl:match("%S")
            and config.mp_curl or config.curl
        if type(mp_source) == "string" then
            local ticket = mp_source:match("%-H%s+['\"][Xx]%-[Ww][Rr]%-[Tt]icket:%s*(.-)['\"]")
            if ticket and ticket ~= "" then
                self.settings:set("wr_ticket", ticket)
            end
            local wrpa = mp_source:match("%-H%s+['\"][Xx]%-[Ww][Rr][Pp][Aa]%-0:%s*(.-)['\"]")
            if wrpa and wrpa ~= "" then
                self.settings:set("wr_wrpa", wrpa)
            end
        end
        if type(config.wr_ticket) == "string" and config.wr_ticket:match("%S") then
            self.settings:set("wr_ticket", config.wr_ticket)
        end
        if type(config.wr_wrpa) == "string" and config.wr_wrpa:match("%S") then
            self.settings:set("wr_wrpa", config.wr_wrpa)
        end
        if type(config.mp_curl) == "string" and config.mp_curl:match("%S") then
            local mp_cookie = Cookie.extract_from_curl(config.mp_curl)
            if mp_cookie and mp_cookie:match("%S") then
                local cookies = Cookie.parse_cookie_header(mp_cookie)
                if Cookie.has_login_cookie(cookies) then
                    imported_cookies = merge_cookie_tables(imported_cookies, cookies)
                end
            end
        end

        if Cookie.has_login_cookie(imported_cookies) then
            self.settings:set("cookies", imported_cookies)
        end

        if curl_payload and curl_payload ~= "" then
            local parsed_ok, payload = pcall(function()
                return self.client:json_decode(curl_payload)
            end)
            if parsed_ok and type(payload) == "table" then
                self.settings:set("curl_payload", payload)
            end
        end
        self.settings:set("config_auth_fingerprint", fingerprint)
        logger.info(LOG_MODULE, "config credentials imported:", "source=", source)
    else
        logger.info(LOG_MODULE, "config credentials unchanged; using persisted credentials")
    end
    self.settings:flush()
    logger.info(LOG_MODULE, "config.lua loaded:", "source=", source)
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
                return self:getReadReportMenuItems()
            end,
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
                    text = T(_("WeRead Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with WeRead's user agreement and applicable laws and regulations.\n\nhttps://github.com/qiuyukang/weread.koplugin"), self.version),
                })
            end,
        },
    }

    if self.ui.document then
        table.insert(items, 1, {
            text = _("Sync progress now") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 2, {
            text = _("Book details") .. "  (" .. _("WIP") .. ")",
            enabled_func = function() return false end,
        })
        table.insert(items, 3, {
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
            text = _("Reload config.lua"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Reload config.lua"), function()
                self:loadConfigFile("manual_reload")
                if self._config_error then
                    self:showInfo(T(_("config.lua error:\n%1"), self._config_error))
                else
                    self:showInfo(_("config.lua loaded."))
                end
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

    table.insert(items, 1, {
        text = _("[Scan] Scan local cache"),
        separator = true,
        callback = self:safeCallback(_("Scan local cache"), function()
            self:confirmScanLocalCache()
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
function WeReadPlugin:scanLocalCache(root, dry_run)
    local lfs = require("libs/libkoreader-lfs")
    local books = self.settings:get("books", {})
    local added, updated = 0, 0
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok then
        return 0, 0
    end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local dir = root .. "/" .. entry
            local attr = lfs.attributes(dir)
            if attr and attr.mode == "directory" then
                local book_id = entry
                local is_mp = WeRead.is_mp_book(book_id)
                -- MP dirs hold .html articles; regular books hold .epub, and we
                -- track the largest one as the book file to open.
                local main_epub, main_size, has_content = nil, -1, false
                local ok2, fiter, fobj = pcall(lfs.dir, dir)
                if ok2 then
                    for f in fiter, fobj do
                        if f ~= "." and f ~= ".." then
                            local fattr = lfs.attributes(dir .. "/" .. f)
                            if fattr and fattr.mode == "file" then
                                local ext = f:match("%.([^.]+)$")
                                ext = ext and ext:lower()
                                if is_mp then
                                    if ext == "html" then
                                        has_content = true
                                    end
                                elseif ext == "epub" then
                                    has_content = true
                                    if (fattr.size or 0) > main_size then
                                        main_size = fattr.size or 0
                                        main_epub = dir .. "/" .. f
                                    end
                                end
                            end
                        end
                    end
                end
                if has_content then
                    local record = books[book_id]
                    local is_new = record == nil
                    if dry_run then
                        if is_new then
                            added = added + 1
                        end
                    else
                        record = record or { book_id = book_id }
                        local changed = is_new
                        if record.cache_dir ~= dir then
                            record.cache_dir = dir
                            changed = true
                        end
                        -- MP articles are opened per-article, not via a single file.
                        if not is_mp and not record.cached_file and main_epub then
                            record.cached_file = main_epub
                            changed = true
                        end
                        if not record.title or record.title == "" then
                            -- MP account names are not on disk, so fall back to the id.
                            record.title = (main_epub and main_epub:match("([^/]+)%.epub$")) or book_id
                            changed = true
                        end
                        if is_new then
                            record.updated_at = os.time()
                        end
                        if changed then
                            books[book_id] = record
                            if is_new then
                                added = added + 1
                            else
                                updated = updated + 1
                            end
                        end
                    end
                end
            end
        end
    end
    if not dry_run then
        self.settings:set("books", books)
        self.settings:flush()
    end
    return added, updated
end

function WeReadPlugin:confirmScanLocalCache()
    self:showBusy(_("Scanning local cache..."))
    UIManager:scheduleIn(0.1, function()
        local added, updated = self:scanLocalCache(self.settings.cache_dir)
        self:closeBusy()
        self:refreshCacheManagement(T(_("Scan complete. %1 added, %2 updated."), tostring(added), tostring(updated)))
    end)
end

-- After the download directory changes, offer to register any untracked items
-- already sitting in the new directory (e.g. manually copied in). base_message is
-- shown when there is nothing to add or the user skips.
function WeReadPlugin:offerScanNewDir(new_dir, base_message)
    local pending = self:scanLocalCache(new_dir, true)
    if pending == 0 then
        self:showInfo(base_message)
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Found %1 untracked item(s) in the new directory. Add them to the library?"), tostring(pending)),
        ok_text = _("Add"),
        ok_callback = function()
            local added = self:scanLocalCache(new_dir)
            self:showInfo(T(_("Added %1 item(s) to the library."), tostring(added)))
        end,
        cancel_text = _("Skip"),
        cancel_callback = function()
            self:showInfo(base_message)
        end,
    })
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
        books[book_id].cached_file = nil
        books[book_id].cached_chapters = nil
        books[book_id].cache_dir = nil
        if WeRead.is_mp_book(book_id) then
            books[book_id].mp_articles = nil
            books[book_id].mp_articles_time = nil
        end
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
            book.cached_file = nil
            book.cached_chapters = nil
            book.cache_dir = nil
            book.mp_articles = nil
            book.mp_articles_time = nil
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
        book.cached_file = nil
        book.cached_chapters = nil
        book.cache_dir = nil
        book.mp_articles = nil
        book.mp_articles_time = nil
    end
    self.settings:set("books", books)
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

function WeReadPlugin:showImportCookieDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Import WeRead cookie or cURL"),
        input = "",
        input_type = "text",
        description = _("Paste a raw Cookie header or a full cURL copied from /web/book/read."),
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
                    text = _("Save"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Save"), function()
                        local input = dialog:getInputText()
                        local cookie_header, curl_data = Cookie.extract_from_curl(input)
                        local cookies = Cookie.parse_cookie_header(cookie_header)
                        if not Cookie.has_login_cookie(cookies) then
                            self:showInfo(_("Could not find a valid wr_skey cookie."))
                            return
                        end
                        self.settings:set("cookies", cookies)
                        if curl_data and curl_data ~= "" then
                            local ok, payload = pcall(function()
                                return self.client:json_decode(curl_data)
                            end)
                            if ok and type(payload) == "table" then
                                self.settings:set("curl_payload", payload)
                            end
                        end
                        self.settings:flush()
                        UIManager:close(dialog)
                        self:renewCookieWithUI()
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function WeReadPlugin:renewCookieWithUI()
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Cookie is not configured."))
        return
    end
    self:runNetworkAction(_("Renew cookie"), function()
        local result = self.client:renew_cookie()
        if result and result.succ then
            logger.info(LOG_MODULE, "cookie renewed")
            return _("WeRead cookie renewed.")
        end
        logger.warn(LOG_MODULE, "cookie renewal completed without succ=1")
        return _("Cookie renewal completed, but response did not include succ=1.")
    end)
end

function WeReadPlugin:showAccountStatus()
    local cookie_status = self.settings:is_cookie_configured() and _("configured") or _("missing")
    local api_status = self.settings:is_api_configured() and _("configured") or _("missing")
    self:showInfo(T(_("Cookie: %1\nOfficial API key: %2\nCache directory:\n%3"), cookie_status, api_status, BD.dirpath(self.settings.cache_dir)))
end

function WeReadPlugin:confirmClearAccount()
    UIManager:show(ConfirmBox:new{
        text = _("Clear WeRead cookie and API key? Cached books will remain."),
        ok_text = _("Clear"),
        ok_callback = self:safeCallback(_("Clear"), function()
            self.settings:reset_account()
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
                return self.settings:get("read_report").report_on_open
            end,
            callback = self:safeCallback(_("Only report when reading"), function()
                local cur = self.settings:get("read_report")
                cur.report_on_open = not cur.report_on_open
                self.settings:set("read_report", cur)
                self.settings:flush()
                if cur.enabled then
                    local has_book = cur.mode == "auto" and self._auto_report_book_id or cur.book_id ~= ""
                    if has_book then
                        if cur.report_on_open and not self.ui.document then
                            self:stopReadReport()
                        else
                            self:maybeStartReadReport()
                        end
                    end
                end
            end),
        },
        {
            text = _("Select target book"),
            post_text = rr.mode == "auto" and _("Auto-associate")
                or (rr.book_title ~= "" and T(_("Manual: %1"), rr.book_title) or _("Not configured")),
            sub_item_table_func = function()
                return self:getReportTargetMenuItems()
            end,
        },
        {
            text = _("Report status"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Report status"), function()
                local cur = self.settings:get("read_report")
                local target
                if cur.mode == "auto" then
                    local auto_title = self._auto_report_book_title
                    target = auto_title and T(_("Auto: %1"), auto_title) or _("Auto-associate")
                else
                    target = cur.book_title ~= "" and cur.book_title or _("Not configured")
                end
                local status = self._report_task and _("Running") or _("Stopped")
                local count = self._report_count or 0
                local last = self._report_last_time
                    and os.date("%H:%M:%S", self._report_last_time) or "--"
                local err = self._report_last_error or ""
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
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key to browse your WeRead shelf. You can still open a book by pasting a reader URL."))
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

function WeReadPlugin:showBookshelf()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key to browse your WeRead shelf. You can still open a book by pasting a reader URL."))
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
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before loading articles."))
        return
    end
    local book_id = book.book_id or book.bookId
    local cached = self:getCachedMPArticles(book_id)
    if cached and #cached > 0 then
        self:showMPArticleList(book, cached)
        return
    end
    self:fetchMPArticles(book, nil)
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

function WeReadPlugin:fetchMPArticles(book, wr_ticket)
    self:runOnlineTask(_("Loading articles..."), function()
        self:showBusy(_("Loading articles..."))
        local book_id = book.book_id or book.bookId
        local ticket = wr_ticket or self.settings:get("wr_ticket", "")
        if ticket == "" then ticket = nil end
        local ok, result, err_code = pcall(function()
            return self.client:get_mp_articles(book_id, 0, 100, ticket)
        end)
        self:closeBusy()
        if not ok then
            logger.err(LOG_MODULE, "load MP articles failed:", log_error(result))
            self:showInfo(T(_("Load articles failed:\n%1"), display_error(result)))
            return
        end
        if not result and (err_code == -2041 or err_code == -2012) then
            logger.warn(LOG_MODULE, "load MP articles rejected, error_code:", tostring(err_code))
            local saved_ticket = self.settings:get("wr_ticket", "")
            if saved_ticket ~= "" then
                self:showInfo(T(_("Load articles failed:\n%1"), "wr_ticket expired, update wr_ticket in config.lua"))
            else
                self:showInfo(_("MP articles require wr_ticket. Set wr_ticket in config.lua, then reload config."))
            end
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

function WeReadPlugin:showWrTicketDialog(book)
    local dialog
    dialog = InputDialog:new{
        title = _("Provide x-wr-ticket"),
        input = self.settings:get("wr_ticket", ""),
        input_type = "text",
        description = _("MP article list requires a browser token.\n\n1. Open weread.qq.com in a browser\n2. Open an MP account page\n3. Open DevTools (F12) → Network tab\n4. Find the /web/mp/articles request\n5. Copy the x-wr-ticket header value\n\nPaste it here (or paste the full cURL):"),
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
                    text = _("Fetch"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Fetch"), function()
                        local input = dialog:getInputText()
                        UIManager:close(dialog)
                        local ticket = input
                        local extracted = input:match("%-H%s+['\"][Xx]%-[Ww][Rr]%-[Tt]icket:%s*(.-)['\"]")
                        if extracted then
                            ticket = extracted
                        elseif input:match("^%s*curl%s") then
                            ticket = nil
                        end
                        if not ticket or ticket == "" then
                            self:showInfo(_("No ticket provided."))
                            return
                        end
                        self.settings:set("wr_ticket", ticket)
                        local wrpa = input:match("%-H%s+['\"][Xx]%-[Ww][Rr][Pp][Aa]%-0:%s*(.-)['\"]")
                        if wrpa and wrpa ~= "" then
                            self.settings:set("wr_wrpa", wrpa)
                        end
                        local raw_cookie = Cookie.extract_from_curl(input)
                        local cookies = Cookie.parse_cookie_header(raw_cookie)
                        if Cookie.has_login_cookie(cookies) then
                            self.settings:set(
                                "cookies",
                                merge_cookie_tables(self.settings:get("cookies", {}), cookies)
                            )
                        end
                        self.settings:flush()
                        self:fetchMPArticles(book, ticket)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
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
            self:showWrTicketDialog(book)
        end),
    })
    self:showList(book.title or _("Public Account"), items, _("No articles."))
end

function WeReadPlugin:downloadMPArticleAndRead(book, article)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading articles."))
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

function WeReadPlugin:loadChapters(book, callback)
    if book.chapters and #book.chapters > 0 then
        callback(book.chapters)
        return
    end
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before loading chapters."))
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
    self:loadChapters(book, function(chapters)
        local items = {}
        for _i, chapter in ipairs(chapters) do
            local cached = book.cached_chapters and book.cached_chapters[tostring(chapter.chapterUid)]
            table.insert(items, {
                text = chapter.title or T(_("Chapter %1"), tostring(chapter.chapterUid)),
                post_text = cached and _("Cached") or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if cached then
                        self:openFile(cached)
                    else
                        self:downloadChapterAndRead(book, chapter)
                    end
                end),
            })
        end
        self:showList(book.title or _("Chapter list"), items, _("No chapters."))
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

function WeReadPlugin:downloadFirstChapterAndRead(book)
    self:loadChapters(book, function(chapters)
        local chapter = Content.first_readable_chapter(chapters)
        if not chapter then
            self:showInfo(_("No readable chapter found"))
            return
        end
        self:confirmAndDownloadChapters(book, { chapter }, "first-chapter", {
            single_chapter = true,
        })
    end)
end

function WeReadPlugin:downloadChapterAndRead(book, chapter)
    self:confirmAndDownloadChapters(book, { chapter }, "chapter", {
        single_chapter = true,
    })
end

function WeReadPlugin:downloadFirstNChapters(book, count)
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading book content."))
        return
    end
    self:loadChapters(book, function(chapters)
        local limit = math.min(count or 5, #chapters)
        local selected = {}
        for chapter_index = 1, limit do
            table.insert(selected, chapters[chapter_index])
        end
        self:confirmAndDownloadChapters(book, selected, "first-" .. tostring(limit))
    end)
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
        self:downloadChaptersAsBook(book, chapters, suffix, options)
        return
    end

    local confirm
    confirm = ConfirmBox:new{
        text = text,
        ok_text = _("Download"),
        ok_callback = self:safeCallback(_("Download"), function()
            UIManager:close(confirm)
            self:downloadChaptersAsBook(book, chapters, suffix, options)
        end),
        cancel_text = _("Close"),
    }
    UIManager:show(confirm)
end

function WeReadPlugin:downloadChaptersAsBook(book, chapters, suffix, options)
    options = options or {}
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before downloading book content."))
        return
    end
    local task_label = options.single_chapter and _("Download chapter and read") or _("Download full book")
    self:runOnlineTask(task_label, function()
        local ok_init, err_init = pcall(function()
            Content.ensure_reader_state(self.client, book)
        end)
        if not ok_init then
            logger.err(LOG_MODULE, "initialize book download failed:", log_error(err_init))
            self:showInfo(T(_("Download failed:\n%1"), display_error(err_init)))
            return
        end

        local total = #chapters
        local dl = {
            book = book,
            chapters = chapters,
            suffix = suffix or "book",
            index = 1,
            cancelled = false,
            selected = {},
            bodies = {},
            assets = {},
            state = {},
            total = total,
            failed = {},
            annotation_failed_batches = 0,
            single_chapter = options.single_chapter == true,
            started_at = time.now(),
        }

        local progress_dialog = DownloadDialog:new{
            title = T(_("Downloading: %1"), book.title or ""),
            progress_max = total,
            buttons = {{
                {
                    text = _("Cancel download"),
                    callback = function()
                        dl.cancelled = true
                        if dl.progress_dialog then
                            dl.progress_dialog:close()
                            dl.progress_dialog = nil
                        end
                    end,
                },
            }},
        }
        dl.progress_dialog = progress_dialog
        progress_dialog:show()
        self:refreshUI()

        UIManager:scheduleIn(0.1, function()
            self:_downloadStep(dl)
        end)
    end)
end

function WeReadPlugin:_setDownloadStage(dl, title, progress)
    if not dl.progress_dialog then return end
    dl.progress_dialog:setTitle(title)
    if progress then
        dl.progress_dialog:reportProgress(progress)
    end
end

function WeReadPlugin:_downloadPerf(dl, stage, started, ...)
    local elapsed = tonumber(time.now() - started) / 1000
    logger.info(LOG_MODULE, "download_perf", "stage=", stage,
        "ms=", string.format("%.1f", elapsed),
        "chapter=", tostring(dl.index) .. "/" .. tostring(dl.total), ...)
end

function WeReadPlugin:_failCurrentDownloadChapter(dl, err)
    local chapter = dl.chapters[dl.index]
    local uid = tostring(chapter and chapter.chapterUid or dl.index)
    table.insert(dl.failed, uid)
    logger.warn(LOG_MODULE, "chapter download failed:",
        "index=", tostring(dl.index) .. "/" .. tostring(dl.total),
        "chapter_uid=", uid, "error=", log_error(err))
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    UIManager:scheduleIn(0.1, function() self:_downloadStep(dl) end)
end

function WeReadPlugin:_finishCurrentDownloadChapter(dl)
    if dl.cancelled or not dl.current then return end
    local chapter = dl.current.chapter
    local cache = self.settings:get("cache")
    local stage_text
    if cache.download_book_images then
        stage_text = T(_("Downloading images · chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    else
        stage_text = T(_("Processing chapter %1/%2"), tostring(dl.index), tostring(dl.total))
    end
    self:_setDownloadStage(dl,
        stage_text, dl.index - 0.1)
    local started = time.now()
    local ok, xhtml, chapter_assets = pcall(function()
        return Content.finalize_single_chapter_content(
            self.client, self.settings, dl.book, chapter, dl.current.xhtml, dl.state
        )
    end)
    self:_downloadPerf(dl, "images_and_finalize", started, "ok=", tostring(ok))
    if not ok then
        self:_failCurrentDownloadChapter(dl, xhtml)
        return
    end
    local uid = tostring(chapter.chapterUid or dl.index)
    dl.bodies[uid] = xhtml
    table.insert(dl.selected, chapter)
    for _i, asset in ipairs(chapter_assets or {}) do
        table.insert(dl.assets, asset)
    end
    dl.current = nil
    dl.annotation = nil
    dl.index = dl.index + 1
    if dl.progress_dialog then
        dl.progress_dialog:reportProgress(dl.index - 1)
    end
    UIManager:scheduleIn(0.1, function() self:_downloadStep(dl) end)
end

function WeReadPlugin:_applyCurrentAnnotations(dl)
    if dl.cancelled or not dl.current or not dl.annotation then return end
    local annotation = dl.annotation
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setDownloadStage(dl,
        T(_("Processing underlines and thoughts · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.15)
    local started = time.now()
    local ok, processed, annotation_css = pcall(function()
        return Thoughts.apply_data(self.settings, book_id, chapter.chapterUid,
            dl.current.xhtml, annotation.underlines, annotation.reviews)
    end)
    self:_downloadPerf(dl, "apply_annotations", started, "ok=", tostring(ok),
        "reviews=", tostring(#annotation.reviews))
    if not ok then
        self:_failCurrentDownloadChapter(dl, processed)
        return
    end
    dl.current.xhtml = processed
    dl.state.annotation_css_seen = dl.state.annotation_css_seen or {}
    if annotation_css ~= "" and not dl.state.annotation_css_seen[annotation_css] then
        dl.state.css = Thoughts.merge_css(dl.state.css, annotation_css)
        dl.state.annotation_css_seen[annotation_css] = true
    end
    self:_finishCurrentDownloadChapter(dl)
end

function WeReadPlugin:_downloadAnnotationBatch(dl)
    if dl.cancelled then
        self:showTransientInfo(_("Download cancelled"), 2)
        return
    end
    local annotation = dl.annotation
    if not annotation then
        self:_finishCurrentDownloadChapter(dl)
        return
    end
    if annotation.batch_index > #annotation.batches then
        self:_applyCurrentAnnotations(dl)
        return
    end

    local batch_index = annotation.batch_index
    local batch_total = #annotation.batches
    local fractional = dl.index - 0.85 + 0.7 * batch_index / math.max(1, batch_total)
    self:_setDownloadStage(dl,
        T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
            tostring(batch_index), tostring(batch_total), tostring(dl.index), tostring(dl.total)),
        fractional)

    local started = time.now()
    local ok, result, err = self.client:get_chapter_reviews_batch(
        dl.book.book_id or dl.book.bookId,
        dl.current.chapter.chapterUid,
        annotation.batches[batch_index]
    )
    self:_downloadPerf(dl, "thought_batch", started,
        "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
        "ok=", tostring(ok), "retry=", tostring(annotation.retry))

    if not ok then
        if annotation.retry < 2 then
            annotation.retry = annotation.retry + 1
            self:_setDownloadStage(dl,
                T(_("Retrying thoughts %1/%2 · attempt %3"),
                    tostring(batch_index), tostring(batch_total), tostring(annotation.retry)),
                fractional)
            UIManager:scheduleIn(0.6 * annotation.retry, function()
                self:_downloadAnnotationBatch(dl)
            end)
            return
        end
        dl.annotation_failed_batches = dl.annotation_failed_batches + 1
        logger.warn(LOG_MODULE, "thought batch skipped:",
            "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
            "error=", log_error(err or "unknown"))
    elseif result and type(result.reviews) == "table" then
        for _, review in ipairs(result.reviews) do
            annotation.reviews[#annotation.reviews + 1] = review
        end
    end

    annotation.batch_index = batch_index + 1
    annotation.retry = 0
    UIManager:scheduleIn(0.3, function() self:_downloadAnnotationBatch(dl) end)
end

function WeReadPlugin:_startCurrentAnnotations(dl)
    local chapter = dl.current.chapter
    local book_id = dl.book.book_id or dl.book.bookId
    self:_setDownloadStage(dl,
        T(_("Downloading underlines · chapter %1/%2"), tostring(dl.index), tostring(dl.total)),
        dl.index - 0.85)
    local started = time.now()
    local ok, underlines, ranges, err = Thoughts.fetch_underlines(
        self.client, self.settings, book_id, chapter.chapterUid
    )
    self:_downloadPerf(dl, "underlines", started, "ok=", tostring(ok),
        "ranges=", tostring(#(ranges or {})))
    if not ok or type(underlines) ~= "table" then
        logger.warn(LOG_MODULE, "skip chapter annotations:", log_error(err or "no data"))
        self:_finishCurrentDownloadChapter(dl)
        return
    end
    dl.annotation = {
        underlines = underlines,
        reviews = {},
        batches = self.client:build_chapter_review_batches(ranges),
        batch_index = 1,
        retry = 0,
    }
    if #dl.annotation.batches == 0 then
        self:_applyCurrentAnnotations(dl)
    else
        UIManager:scheduleIn(0.1, function() self:_downloadAnnotationBatch(dl) end)
    end
end

function WeReadPlugin:_downloadStep(dl)
    if dl.cancelled then
        self:showTransientInfo(_("Download cancelled"), 2)
        return
    end

    if dl.index > dl.total then
        if #dl.selected == 0 then
            if dl.progress_dialog then
                dl.progress_dialog:close()
                dl.progress_dialog = nil
            end
            logger.err(LOG_MODULE, "book download failed: no chapters downloaded")
            self:showInfo(_("No chapters were downloaded."))
            return
        end
        self:_setDownloadStage(dl, _("Building EPUB..."), dl.total)
        local save_started = time.now()
        local ok, path = pcall(function()
            if dl.single_chapter then
                local chapter = dl.selected[1]
                local uid = tostring(chapter.chapterUid or 1)
                return Content.save_chapter_epub(
                    self.settings, dl.book, chapter, dl.bodies[uid], dl.assets, dl.state.css
                )
            end
            local cover_data
            local cover_url = WeRead.normalize_cover_url(dl.book.cover)
            if cover_url and cover_url ~= "" then
                pcall(function() cover_data = self.client:get_binary(cover_url) end)
            end
            return Content.save_book_epub(
                self.settings, dl.book, dl.selected, dl.bodies,
                dl.suffix, dl.assets, dl.state.css, cover_data
            )
        end)
        self:_downloadPerf(dl, "save_epub", save_started, "ok=", tostring(ok),
            "single=", tostring(dl.single_chapter))
        if dl.progress_dialog then
            dl.progress_dialog:close()
            dl.progress_dialog = nil
        end
        local books = self.settings:get("books", {})
        local book_id = dl.book.book_id or dl.book.bookId
        if book_id then
            dl.book.cached_chapters = dl.book.cached_chapters or {}
            for ci, ch in ipairs(dl.selected) do
                dl.book.cached_chapters[tostring(ch.chapterUid or ci)] = ok and path or nil
            end
            if ok then
                dl.book.cached_file = path
            end
            dl.book.reader_url = dl.book.reader_url or WeRead.reader_url(book_id)
            books[book_id] = dl.book
            self.settings:set("books", books)
            self.settings:flush()
        end
        self:refreshShelfCacheIndicators()
        if not ok then
            logger.err(LOG_MODULE, "save downloaded book failed:", log_error(path))
            self:showInfo(T(_("Download failed:\n%1"), display_error(path)))
            return
        end
        if #dl.failed > 0 then
            logger.warn(
                LOG_MODULE,
                "book download completed with skipped chapters:",
                "success=", tostring(#dl.selected),
                "failed=", tostring(#dl.failed)
            )
        else
            logger.info(LOG_MODULE, "book download completed:", "chapters=", tostring(#dl.selected))
        end
        local completion_text
        if #dl.failed > 0 then
            completion_text = T(
                _("Downloaded %1 chapters; %2 failed.\n\nBook saved:\n%3\n\nRead now?"),
                tostring(#dl.selected), tostring(#dl.failed), path
            )
        else
            completion_text = T(_("Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"), tostring(#dl.selected), path)
        end
        if dl.annotation_failed_batches > 0 then
            completion_text = completion_text .. "\n\n" .. T(
                _("%1 thought batch(es) failed after retries; the EPUB contains the remaining available thoughts."),
                tostring(dl.annotation_failed_batches)
            )
        end
        self:_downloadPerf(dl, "download_total", dl.started_at,
            "success_chapters=", tostring(#dl.selected),
            "failed_chapters=", tostring(#dl.failed),
            "failed_thought_batches=", tostring(dl.annotation_failed_batches))
        UIManager:show(ConfirmBox:new{
            text = completion_text,
            ok_text = _("Read now"),
            ok_callback = self:safeCallback(_("Read now"), function()
                self:openFile(path)
            end),
            cancel_text = _("Close"),
        })
        return
    end

    local chapter = dl.chapters[dl.index]
    self:_setDownloadStage(dl,
        T(_("Downloading chapter %1/%2: %3"), tostring(dl.index), tostring(dl.total),
            chapter.title or tostring(chapter.chapterUid)),
        dl.index - 1)
    local started = time.now()
    local ok, xhtml = pcall(function()
        return Content.fetch_single_chapter_source(
            self.client, self.settings, dl.book, chapter, dl.state
        )
    end)
    self:_downloadPerf(dl, "chapter_source", started, "ok=", tostring(ok))
    if not ok then
        self:_failCurrentDownloadChapter(dl, xhtml)
        return
    end
    dl.current = { chapter = chapter, xhtml = xhtml }
    if Thoughts.is_download_enabled(self.settings) then
        self:_startCurrentAnnotations(dl)
    else
        self:_finishCurrentDownloadChapter(dl)
    end
end

function WeReadPlugin:pullProgressWithUI(book_id)
    self:runNetworkAction(_("Pull progress"), function()
        local result = self.client:get_progress(book_id)
        local progress = result and result.book and result.book.progress or 0
        return T(_("Remote progress: %1%"), tostring(progress))
    end)
end

function WeReadPlugin:showSearch()
    if not self.settings:is_api_configured() then
        self:showInfo(_("Set the official API key before using WeRead search."))
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
    if not self.settings:is_cookie_configured() then
        self:showInfo(_("Import cookie/cURL before parsing reader URLs."))
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
    self:showInfo(_("Current-book WeRead metadata is not linked yet. Open a parsed WeRead book from the plugin cache first."))
end

function WeReadPlugin:onShowWeRead()
    self:showAccountStatus()
end

function WeReadPlugin:onWeReadSyncProgress()
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
        app_id = book.app_id or self.settings:get("curl_payload", {}).appId,
        psvts = book.psvts or self.settings:get("curl_payload", {}).ps,
        pclts = book.pclts or self.settings:get("curl_payload", {}).pc,
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
    ".wr-underline{border-bottom:0 !important;padding-bottom:0 !important;} .wr-star{font-size:0 !important;}"

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

function WeReadPlugin:_teardownThoughtInterception()
    if self._thought_interception_setup and self.ui then
        self.ui:unRegisterTouchZones({
            { id = "weread_thought_tap", overrides = { "tap_link" } },
        })
        self._thought_interception_setup = nil
    end
    ThoughtPopup.closeVisible()
    ThoughtPopup.cancelPrewarm()
    self._thought_popup_open = nil
    self._current_thought_popup = nil
    self._thought_html_cache = nil
    self._thought_highlight_active = nil
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

function WeReadPlugin:_onThoughtTap(ges)
    local tap_started = time.now()
    if not self.ui or not self.ui.document or not self.ui.link then
        return false
    end
    if not self:detectWeReadBook() then
        return false
    end

    local link_started = time.now()
    local link = self.ui.link:getLinkFromGes(ges)
    thought_perf("link_lookup", link_started, "found=", tostring(link ~= nil))
    if not link or not link.xpointer then
        return false
    end

    local html
    local cache_hit = false
    local cache = self._thought_html_cache
    if cache and cache[link.xpointer] ~= nil then
        cache_hit = true
        local cached = cache[link.xpointer]
        if cached == false then
            return false
        end
        html = cached
    else
        local extract_started = time.now()
        -- The generated EPUB groups all thought asides in one footnotes section.
        -- Asking CREngine for the "final parent" expands a single target aside
        -- to that whole section, which mixes unrelated thoughts and makes MuPDF
        -- lay out hundreds of footnotes. The link target itself is already the
        -- complete <aside>, so keep extraction scoped to that node.
        html = self.ui.document:getHTMLFromXPointer(link.xpointer, 0x1001, false)
        thought_perf("extract_html", extract_started,
            "html_bytes=", tostring(type(html) == "string" and #html or 0))
        if type(html) ~= "string" or not html:find("weread%-thought") then
            self._thought_html_cache = self._thought_html_cache or {}
            self._thought_html_cache[link.xpointer] = false
            return false
        end
        self._thought_html_cache = self._thought_html_cache or {}
        self._thought_html_cache[link.xpointer] = html
    end
    thought_perf("tap_resolve", tap_started, "cache_hit=", tostring(cache_hit),
        "html_bytes=", tostring(#html))

    -- When annotations are hidden, still consume the tap so KOReader's built-in
    -- footnote popup (triggered by the epub:type="noteref" link) does not fire,
    -- but do not show our own thought popup either.
    if self.settings:get("cache").show_annotations == false then
        return true
    end

    if self._thought_popup_open then
        return true
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

function WeReadPlugin:onReaderReady()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()

    local weread_book_id = self:detectWeReadBook()
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
    end

    local rr = self.settings:get("read_report")
    if rr.mode == "auto" and rr.enabled then
        if weread_book_id then
            self._auto_report_book_id = weread_book_id
            local books = self.settings:get("books", {})
            local book_record = books[weread_book_id]
            self._auto_report_book_title = book_record and book_record.title or weread_book_id
            self:startReadReport(true)
            self:showTransientInfo(T(_("Reading time report started: %1"), self._auto_report_book_title), 2)
        else
            self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
        end
    else
        self:maybeStartReadReport()
    end
end

function WeReadPlugin:onCloseDocument()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()

    local rr = self.settings:get("read_report")
    if rr.mode == "auto" then
        self._auto_report_book_id = nil
        self._auto_report_book_title = nil
        self:stopReadReport()
    elseif rr.report_on_open then
        self:stopReadReport()
    end
end

function WeReadPlugin:maybeStartReadReport()
    local rr = self.settings:get("read_report")
    if not rr.enabled then
        return
    end
    if rr.mode == "auto" then
        if not self._auto_report_book_id then
            return
        end
    elseif rr.book_id == "" then
        return
    end
    if rr.report_on_open and not self.ui.document then
        return
    end
    if not self._report_task then
        self:startReadReport(not rr.report_on_open)
    end
end

function WeReadPlugin:startReadReport(silent)
    self:stopReadReport()
    local rr = self.settings:get("read_report")
    local interval = rr.interval_seconds or 30
    self._report_count = 0
    self._report_last_time = nil
    self._report_last_error = nil
    self._report_logged_error = nil
    self._report_task = function()
        local ok, err = pcall(function()
            self:doReadReport()
        end)
        if not ok then
            self:setReadReportError(err, "report task error:")
        end
        if self._report_task then
            UIManager:scheduleIn(interval, self._report_task)
        end
    end
    UIManager:scheduleIn(interval, self._report_task)
    logger.info(LOG_MODULE, "reading time report started")
    if not silent then
        self:showTransientInfo(T(_("Reading time report started: %1"), rr.book_title or rr.book_id), 1)
    end
end

function WeReadPlugin:stopReadReport()
    if self._report_task then
        UIManager:unschedule(self._report_task)
        self._report_task = nil
        logger.info(LOG_MODULE, "reading time report stopped, success_count:", self._report_count or 0)
    end
end

function WeReadPlugin:setReadReportError(err, log_prefix, update_status)
    local message = tostring(err)
    if update_status ~= false then
        self._report_last_error = message
    end
    if self._report_logged_error ~= message then
        logger.warn(LOG_MODULE, log_prefix or "read report error:", log_error(message))
        self._report_logged_error = message
    end
end

function WeReadPlugin:recordReadReportSuccess()
    local recovered = self._report_last_error ~= nil
    self._report_count = (self._report_count or 0) + 1
    self._report_last_time = os.time()
    self._report_last_error = nil
    self._report_logged_error = nil
    if recovered or self._report_count == 1 or self._report_count % 20 == 0 then
        logger.info(LOG_MODULE, "read report success, count:", self._report_count)
    end
end

function WeReadPlugin:doReadReport()
    local rr = self.settings:get("read_report")
    local report_book_id = rr.mode == "auto" and self._auto_report_book_id or rr.book_id
    if not rr.enabled or not report_book_id or report_book_id == "" then
        return
    end
    if not self.settings:is_cookie_configured() then
        self:setReadReportError("cookie not configured", "read report skipped:", false)
        return
    end
    local curl_payload = self.settings:get("curl_payload", {})
    local now = os.time()
    local ts = now * 1000 + math.random(0, 999)
    local rn = math.random(0, 999)
    local token = WeRead.DEFAULT_READER_TOKEN
    local payload = {
        appId = curl_payload.appId or WeRead.web_app_id(),
        b = WeRead.e(report_book_id),
        c = curl_payload.c or WeRead.e(0),
        ci = curl_payload.ci or 27,
        co = curl_payload.co or 389,
        sm = curl_payload.sm or "",
        pr = curl_payload.pr or 74,
        rt = rr.interval_seconds or 30,
        ts = ts,
        rn = rn,
        sg = Crypto.sha256_hex(tostring(ts) .. tostring(rn) .. token),
        ct = now,
        ps = curl_payload.ps or WeRead.e(now - 1),
        pc = WeRead.e(now),
    }
    payload.s = WeRead.sign(WeRead.sorted_query(payload))
    local ok, result = pcall(function()
        return self.client:report_read(payload)
    end)
    if ok and result and result.succ then
        self:recordReadReportSuccess()
        return
    end
    if ok and result and not result.succ then
        local renew_ok = pcall(function()
            self.client:renew_cookie()
        end)
        if renew_ok then
            local ok2, result2 = pcall(function()
                return self.client:report_read(payload)
            end)
            if ok2 and result2 and result2.succ then
                self:recordReadReportSuccess()
                return
            end
        end
        self:setReadReportError(_("Cookie expired"))
        return
    end
    if not ok then
        self:setReadReportError(result)
    end
end

function WeReadPlugin:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return WeReadPlugin
