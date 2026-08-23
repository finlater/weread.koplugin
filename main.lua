local Event = require("ui/event")
local logger = require("weread.lib.logger")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Client = require("weread.lib.client")
local Content = require("weread.lib.content")
local Downloader = require("weread.lib.downloader")
local ExternalAnnotationsDB = require("weread.lib.external_annotations_db")
local Integrations = require("integrations.init")
local LibraryDB = require("weread.lib.library_db")
local Mixin = require("weread.lib.mixin")
local Migrations = require("weread.lib.migrations")
local PluginUtil = require("weread.lib.plugin_util")
local ProgressSync = require("weread.lib.progress_sync")
local ProgressSyncDialog = require("weread.ui.progress_sync_dialog")
local QRLogin = require("weread.lib.qr_login")
local ReadReport = require("weread.lib.read_report")
local Settings = require("weread.lib.settings")

local _ = PluginUtil.tr

local function read_plugin_version()
    local info = debug.getinfo(1, "S")
    local source = info and info.source or ""
    local dir = source:match("^@(.*/)[^/]+$")
    if dir then
        local file = io.open(dir .. "_meta.lua", "rb")
        if file then
            local body = file:read("*a") or ""
            file:close()
            local version = body:match('[Vv]ersion%s*=%s*"([^"]+)"')
                or body:match("[Vv]ersion%s*=%s*'([^']+)'")
            if version and version ~= "" then
                return version
            end
        end
    end
    return "0.5.0"
end

local WeReadPlugin = WidgetContainer:extend{
    name = "weread",
    is_doc_only = false,
    version = read_plugin_version(),
}

-- Stable entry point used by third-party launchers such as SimpleUI and ZenUI.
function WeReadPlugin:openBookshelf()
    return self:showBookshelf()
end

-- Both SimpleUI and ZenUI discover conventional plugin launch methods.
function WeReadPlugin:launch()
    return self:openBookshelf()
end

function WeReadPlugin:onZenUIReady()
    Integrations.onZenUIReady(self)
    return true
end

function WeReadPlugin:init()
    math.randomseed(os.time())
    self.settings = Settings:new()
    if type(PluginUtil.set_perf_enabled) == "function" then
        local advanced = self.settings:get("advanced", {})
        PluginUtil.set_perf_enabled(advanced.developer_logs == true)
    end
    self.external_annotations_db = ExternalAnnotationsDB:new(self.settings)
    self.library_db = LibraryDB:new(self.settings)
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
        run_online_task = function(label, fn)
            return self:runOnlineTask(label, fn)
        end,
        run_background_task = function(fn)
            UIManager:scheduleIn(0.1, fn)
            return true
        end,
        is_connected = function()
            return self:isNetworkConnected()
        end,
    }
    Migrations.run(self.settings, self.client)
    self.external_annotations_db:migrateLegacySettings()
    if self.downloader.recover then
        self.downloader:recover()
    end
    self.qr_login = QRLogin:new(self, self.client, self.settings)
    self.read_report = ReadReport:new{
        settings = self.settings,
        client = self.client,
        library_db = self.library_db,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        position_provider = function(book_id)
            if not self.progress_sync then
                return nil, "progress_sync_initializing", true
            end
            return self.progress_sync:position_for_report(book_id)
        end,
        -- The report tick runs on the UI loop; use the link-state check here
        -- because NetworkMgr:isOnline() does a blocking DNS lookup.
        is_online = function()
            return self:isNetworkConnected()
        end,
    }
    self.progress_sync = ProgressSync:new{
        settings = self.settings,
        client = self.client,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        get_footer = function()
            return self.ui and self.ui.view and self.ui.view.footer
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        get_book = function(book_id)
            return self.settings:get("books", {})[tostring(book_id)]
        end,
        get_chapters = function(book)
            return self:ensureChaptersLoaded(book)
        end,
        refresh_catalog = function(book_id)
            local book = self.settings:get("books", {})[tostring(book_id)]
            if type(book) ~= "table" then
                return nil, "book_not_found"
            end
            local ok, chapters_or_err = pcall(function()
                Content.ensure_reader_state(self.client, book)
                return Content.fetch_catalog(self.client, book)
            end)
            if not ok then
                return nil, chapters_or_err
            end
            local chapters = chapters_or_err
            if type(chapters) ~= "table" or #chapters == 0 then
                return nil, "catalog_unavailable"
            end
            local cache_ok, cache_err = Content.save_catalog_cache(
                self.client, self.settings, book, chapters)
            if not cache_ok then
                logger.warn("save chapter catalog cache failed:",
                    PluginUtil.log_error(cache_err))
            end
            if self.library_db then
                self.library_db:putChapters(book_id, chapters)
            end
            return chapters
        end,
        get_file_context = function(book, path)
            return self:getChapterInfoFromFile(book, path)
        end,
        run_online = function(_kind, callback)
            return self:runOnlineTask(_("Sync progress"), callback)
        end,
        upload_position = function(book_id, position, elapsed_seconds)
            return self.read_report:upload_position(
                book_id, position, elapsed_seconds)
        end,
        build_upload_outcome = function(book_id, position, elapsed_seconds)
            return self.read_report:build_position_upload_outcome(
                book_id, position, elapsed_seconds)
        end,
        apply_upload_outcome = function(book_id, outcome)
            return self.read_report:apply_position_upload_outcome(
                book_id, outcome)
        end,
        goto_fraction = function(fraction)
            local percent = math.floor(
                math.max(0, math.min(1, tonumber(fraction) or 0))
                    * 100 + 0.5)
            return pcall(function()
                if self.ui and self.ui.rolling
                    and self.ui.rolling.onGotoPercent then
                    self.ui.rolling:onGotoPercent(percent)
                elseif self.ui then
                    self.ui:handleEvent(Event:new("GotoPercent", percent))
                else
                    error("reader unavailable")
                end
            end)
        end,
        open_chapter = function(book, chapter)
            return self:openProgressTargetChapter(book, chapter)
        end,
        is_online = function()
            return self:isNetworkConnected()
        end,
        on_choice = function(context)
            ProgressSyncDialog.show_choice(context)
        end,
        notify = function(code, data)
            ProgressSyncDialog.notify(code, data)
        end,
    }
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self.integrations = Integrations
    self.integrations.register(self)
    local read_report = self.settings:get("read_report")
    if read_report.enabled
        and read_report.mode == "manual"
        and read_report.book_id ~= ""
        and read_report.report_on_open == false then
        self.read_report:maybe_start("plugin_start")
    end
    self._reader_session_gen = 0
    logger.info("initialized:", "version=", self.version)
    if self.maybeCheckPluginUpdateOnStart then
        self:maybeCheckPluginUpdateOnStart()
    end
end

Mixin.apply(WeReadPlugin, {
    (require("weread.ui.common")),
    (require("weread.ui.menu")),
    (require("weread.ui.update")),
    (require("weread.ui.cache")),
    (require("weread.ui.read_report")),
    (require("weread.ui.library")),
    (require("weread.ui.annotations_controller")),
    (require("weread.ui.xpointer_overlay_controller")),
    (require("weread.ui.reader_navigation")),
    (require("weread.lib.reader_lifecycle")),
})

return WeReadPlugin
