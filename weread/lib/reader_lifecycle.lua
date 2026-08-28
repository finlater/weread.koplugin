-- KOReader event lifecycle and reader-state orchestration.
local Content = require("weread.lib.content")
local logger = require("weread.lib.logger").scoped("Prefetch")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local WeRead = require("weread.lib.protocol")
local _ = PluginUtil.tr
local T = PluginUtil.T
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists
local log_error = PluginUtil.log_error
local ok_time, time = pcall(require, "ui/time")
if not ok_time then
    time = { now = function() return 0 end }
end
local perf = PluginUtil.perf or function() end

local M = {}

-- KOReader v2026.03 assumes ReaderHighlight's visible box cache has already
-- been populated when a tap arrives. During a fast document switch there is a
-- short window after ReaderReady where the cache is still nil, and the native
-- handler crashes while taking its length. Keep the compatibility guard local
-- to the reader instance and leave KOReader's normal handler unchanged once
-- the cache has been initialized.
function M:_installReaderHighlightTapGuard()
    local highlight = self.ui and self.ui.highlight
    if not highlight or type(highlight.onTap) ~= "function" then
        return false
    end
    if self._reader_highlight_guard_target == highlight then
        return true
    end
    self:_removeReaderHighlightTapGuard()

    local original = highlight.onTap
    self._reader_highlight_guard_target = highlight
    self._reader_highlight_original_on_tap = original
    highlight.onTap = function(highlight_self, arg, ges)
        local view_highlight = highlight_self.view and highlight_self.view.highlight
        if ges and view_highlight and type(view_highlight.visible_boxes) ~= "table" then
            view_highlight.visible_boxes = {}
        end
        return original(highlight_self, arg, ges)
    end
    return true
end

function M:_removeReaderHighlightTapGuard()
    local highlight = self._reader_highlight_guard_target
    local original = self._reader_highlight_original_on_tap
    if highlight and original and highlight.onTap ~= original then
        highlight.onTap = original
    end
    self._reader_highlight_guard_target = nil
    self._reader_highlight_original_on_tap = nil
end

function M:onShowWeRead()
    self:showAccountStatus()
end

function M:onWeReadSyncProgress()
    local book_id = self:detectWeReadBook()
    if not book_id or WeRead.is_mp_book(book_id) then
        self:showTransientInfo(
            _("This action requires an open WeRead book."), 1)
        return false
    end
    if not self:requireLogin(true, false) then
        return false
    end
    self.progress_sync:sync_now()
    return true
end

function M:handleEndOfBook(status_self)
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

function M:onReaderReady()
    local total_started = time.now()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()
    self._current_weread_file = nil
    self._current_weread_book_id = nil
    self:_installReaderHighlightTapGuard()

    local current_file = self.ui and self.ui.document and self.ui.document.file
    local detect_started = time.now()
    local weread_book_id = self:detectWeReadBook()
    perf("reader_ready.detect_book", detect_started)
    -- Cache it so lifecycle callbacks and the per-tap handler do not have to
    -- rescan the whole book table for the same document.
    self._current_weread_file = current_file
    self._current_weread_book_id = weread_book_id
    if weread_book_id then
        -- Always register the tap interception: even when annotations are hidden
        -- we must intercept taps on thought links to suppress the native footnote
        -- popup. Visibility is decided inside _onThoughtTap / applyAnnotationVisibility.
        self:_setupThoughtInterception()
        -- ThoughtDB is intentionally lazy: opening a document must not perform
        -- SQLite I/O on the reader lifecycle. It is opened on the first thought
        -- tap instead.
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

    -- Register the EPUB-safe external annotation prototype for any CREngine
    -- document. The view module remains empty until the user adds a prototype
    -- range, so unsupported/non-participating books pay only an empty module
    -- function call during paint.
    self:_setupXPointerOverlayPrototype()

    local sync_started = time.now()
    self.progress_sync:on_reader_ready()
    perf("reader_ready.progress_sync", sync_started)
    -- Auto mode silently skips non-WeRead documents; no toast (still logged by ReadReport).
    local prefetch_session_gen = self._reader_session_gen
    UIManager:scheduleIn(0.2, function()
        if prefetch_session_gen ~= self._reader_session_gen then return end
        self:maybePrefetchNextChapter(weread_book_id)
    end)
    local report_started = time.now()
    self.read_report:on_reader_ready()
    perf("reader_ready.read_report", report_started)
    perf("reader_ready.total", total_started)
end

function M:onPageUpdate()
    self.progress_sync:on_page_update()
end

function M:onCloseDocument()
    local total_started = time.now()
    -- Capture the immutable local position while the document is still alive.
    -- The network upload is scheduled; stopping ReadReport below also frees any
    -- in-flight report slot before that scheduled upload begins.
    local sync_started = time.now()
    self.progress_sync:on_close_document()
    perf("close.progress_sync", sync_started)
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self.downloader:cancelPrefetch("document_closed")
    self._current_weread_file = nil
    self._current_weread_book_id = nil
    self:_teardownThoughtInterception()
    require("weread.ui.thought_popup").cleanup()
    self:_teardownXPointerOverlayPrototype()
    self:_removeReaderHighlightTapGuard()

    if self._orig_onEndOfBook and self.ui.status then
        self.ui.status.onEndOfBook = self._orig_onEndOfBook
        self._orig_onEndOfBook = nil
    end

    local report_started = time.now()
    self.read_report:on_close_document()
    perf("close.read_report", report_started)
    perf("close.total", total_started)
end

function M:showPrefetchNotice(text, timeout)
    if self.settings:get("cache").show_prefetch_notifications == false then
        return
    end
    self:showTransientInfo(text, timeout or 1)
end

function M:maybePrefetchNextChapter(book_id)
    local cache = self.settings:get("cache")
    if cache.auto_prefetch_next_chapter ~= true or not book_id then
        self.downloader:cancelPrefetch("prefetch_not_applicable")
        return false
    end

    local books = self.settings:get("books", {})
    local book = books[tostring(book_id)] or books[book_id]
    local chapters = self:ensureChaptersLoaded(book)
    local file = self.ui.document and self.ui.document.file
    if not book or not chapters or not file then
        self.downloader:cancelPrefetch("prefetch_context_missing")
        return false
    end
    local chapter_info = { self:getChapterInfoFromFile(book, file) }
    local current_index, is_full_book = chapter_info[1], chapter_info[3]
    local next_chapter = not is_full_book and current_index
        and chapters[current_index + 1] or nil
    if not next_chapter then
        self.downloader:cancelPrefetch("no_next_chapter")
        return false
    end

    local next_uid = tostring(next_chapter.chapterUid or next_chapter.chapterId or "")
    local cached = book.cached_chapters and book.cached_chapters[next_uid]
    if file_exists(cached) then
        if not self.downloader:isPrefetching(book, next_chapter) then
            self.downloader:cancelPrefetch("next_chapter_cached")
        end
        return true
    end
    if self.downloader:isPrefetching(book, next_chapter) then
        return true
    end

    local title = next_chapter.title or T(_("Chapter %1"), next_uid)
    return self.downloader:start(book, { next_chapter }, "chapter", {
        single_chapter = true,
        include_annotations = cache.download_underlines_and_thoughts == true,
        prefetch = true,
        start_delay = cache.show_prefetch_notifications == false and 0.1 or 0.7,
        silent_completion = true,
        offer_read = false,
        on_start = function()
            logger.info("started:",
                "book_id=", tostring(book_id),
                "chapter_uid=", next_uid,
                "title=", title)
            self:showPrefetchNotice(
                T(_("Prefetching next chapter: %1"), title), 0.5)
        end,
        on_complete = function(ok, value)
            if ok then
                logger.info("succeeded:",
                    "book_id=", tostring(book_id),
                    "chapter_uid=", next_uid,
                    "title=", title)
                self:showPrefetchNotice(T(_("Next chapter prefetched: %1"), title))
                return
            end
            local retry_requested = self.downloader:isPromotedPrefetch(
                book, next_chapter)
            if value == "cancelled" or value == "document_closed"
                or value == "replaced" or value == "manual_download"
                or value == "setting_disabled" or value == "prefetch_not_applicable"
                or value == "prefetch_context_missing" or value == "no_next_chapter"
                or value == "next_chapter_cached" then
                logger.info("ended without completion:",
                    "book_id=", tostring(book_id),
                    "chapter_uid=", next_uid,
                    "title=", title,
                    "reason=", tostring(value))
                return
            end
            local reason = value == "offline" and _("Network is not connected")
                or display_error(value)
            logger.warn("failed:",
                "book_id=", tostring(book_id),
                "chapter_uid=", next_uid,
                "title=", title,
                "reason=", log_error(value))
            self:showPrefetchNotice(T(_("Next chapter prefetch failed: %1"), reason))
            if retry_requested then
                local source_file = file
                local retry_cache = self.settings:get("cache")
                local retry_delay = retry_cache.show_prefetch_notifications == false
                    and 0.1 or 1.1
                UIManager:scheduleIn(retry_delay, function()
                    if self.ui.document and self.ui.document.file == source_file then
                        self:downloadChapterAndRead(book, next_chapter)
                    end
                end)
            end
        end,
    })
end

function M:maybeStartReadReport()
    return self.read_report:maybe_start("menu")
end

function M:stopReadReport(reason)
    self.read_report:stop(reason or "explicit_stop")
end

function M:onSuspend()
    self.progress_sync:on_suspend()
    self.read_report:on_suspend()
end

function M:onResume()
    self.progress_sync:on_resume()
    self.read_report:on_resume()
end

function M:onNetworkConnected()
    self.progress_sync:on_network_connected()
end

function M:detectWeReadBook()
    if not self.ui.document then
        return nil
    end
    local file = self.ui.document.file
    if not file then
        return nil
    end

    if self._current_weread_file == file then
        return self._current_weread_book_id
    end

    local function remember(book_id)
        self._current_weread_file = file
        self._current_weread_book_id = book_id
        return book_id
    end

    -- Flat EPUBs can be resolved from the compact raw index without hydrating
    -- every BookStore record during the reader lifecycle.
    if self.settings.find_book_id_by_path then
        local indexed = self.settings:find_book_id_by_path(file)
        if indexed then
            return remember(indexed)
        end
    end

    local books = self.settings:get("books", {})

    -- Legacy/nested content still living under a bookId sidecar/content dir.
    for book_id, book in pairs(books) do
        if type(book) == "table" then
            local dir = Content.book_resolved_dir(
                self.settings, book_id, book):gsub("/+$", "") .. "/"
            if file:sub(1, #dir) == dir then
                return remember(book_id)
            end
        end
    end

    -- Legacy path layout only: <download>/<book_id>/file.epub
    local prefix = self.settings.cache_dir:gsub("/+$", "") .. "/"
    if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        local nested_id = rest:match("^([^/]+)/")
        if nested_id and books[nested_id] then
            return remember(nested_id)
        end
        if nested_id then
            return remember(nested_id)
        end
    end

    -- Opened a file under metadata tree (rare; MP html etc.).
    local meta_root = self.settings.meta_dir
    if type(meta_root) == "string" and meta_root ~= "" then
        local meta_prefix = meta_root:gsub("/+$", "") .. "/"
        if file:sub(1, #meta_prefix) == meta_prefix then
            local rest = file:sub(#meta_prefix + 1)
            return remember(rest:match("^([^/]+)"))
        end
    end
    return remember(nil)
end

function M:ensureChaptersLoaded(book)
    if not book then return nil end
    if type(book.chapters) == "table" and #book.chapters > 0 then
        local book_id = book.book_id or book.bookId
        if self.library_db and book_id then
            self.library_db:putChapters(book_id, book.chapters)
        end
        local catalog_path = Content.catalog_cache_path(self.settings, book)
        if catalog_path and not file_exists(catalog_path) then
            local cache_ok, cache_err = Content.save_catalog_cache(
                self.client, self.settings, book, book.chapters)
            if not cache_ok then
                logger.warn("save chapter catalog cache failed:",
                    log_error(cache_err))
            end
        end
        return book.chapters
    end

    local book_id = book.book_id or book.bookId
    local chapters = Content.load_catalog_cache(
        self.client, self.settings, book)
    if type(chapters) == "table" and #chapters > 0 then
        if self.library_db then
            self.library_db:putChapters(book_id, chapters)
        end
        return chapters
    end

    chapters = self.library_db and self.library_db:getChapters(book_id) or nil
    if type(chapters) == "table" and #chapters > 0 then
        book.chapters = chapters
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            logger.warn("save chapter catalog cache failed:",
                log_error(cache_err))
        end
        return chapters
    end
    return nil
end

-- cached_file historically pointed at either a full-book EPUB or the most
-- recently downloaded single chapter. Treat it as a legacy full-book path only
-- when it does not map to exactly one chapter; new downloads use the explicit
-- cached_full_book field.
function M:getFullBookCachePath(book)
    if type(book) ~= "table" then return nil end
    if type(book.cached_full_book) == "string"
        and book.cached_full_book ~= "" and file_exists(book.cached_full_book) then
        return book.cached_full_book
    end
    local legacy = book.cached_file
    if type(legacy) ~= "string" or legacy == "" then return nil end
    local mapped_count = 0
    for _uid, path in pairs(book.cached_chapters or {}) do
        if path == legacy then mapped_count = mapped_count + 1 end
    end
    if mapped_count == 1 then return nil end
    return legacy
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
function M:getChapterInfoFromFile(book, file_path)
    if not book or not file_path or not book.chapters then
        return nil, nil, false
    end

    local mapped_count = 0
    local current_uid = nil
    for uid, path in pairs(book.cached_chapters or {}) do
        if path == file_path then
            mapped_count = mapped_count + 1
            current_uid = uid
        end
    end

    local full_book_path = self:getFullBookCachePath(book)
    if full_book_path == file_path then
        return nil, nil, true
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

function M:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return M
