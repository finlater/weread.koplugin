-- KOReader event lifecycle and reader-state orchestration.
local Content = require("weread.lib.content")
local UIManager = require("ui/uimanager")
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr

local M = {}

function M:onShowWeRead()
    self:showAccountStatus()
end

function M:onWeReadSyncProgress()
    if not self:requireLogin(true, false) then
        return
    end
    self.progress_sync:sync_now()
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
        if self.settings:get("cache").show_annotations ~= false then
            local db_session_gen = self._reader_session_gen
            UIManager:scheduleIn(0.1, function()
                if db_session_gen ~= self._reader_session_gen
                    or self._current_weread_book_id ~= weread_book_id then
                    return
                end
                self:_ensureThoughtDB(weread_book_id)
            end)
        end
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

    self.progress_sync:on_reader_ready()
    local _started, _title, reason = self.read_report:on_reader_ready()
    local rr = self.settings:get("read_report")
    if rr.enabled and rr.mode == "auto" and reason == "document_not_weread" then
        self:showTransientInfo(_("Current book is not from WeRead, reading time not reported"), 1)
    end
end

function M:onPageUpdate()
    self.progress_sync:on_page_update()
end

function M:onCloseDocument()
    -- Capture the immutable local position while the document is still alive.
    -- The network upload is scheduled; stopping ReadReport below also frees any
    -- in-flight report slot before that scheduled upload begins.
    self.progress_sync:on_close_document()
    self._reader_session_gen = (self._reader_session_gen or 0) + 1
    self:_teardownThoughtInterception()

    if self._orig_onEndOfBook and self.ui.status then
        self.ui.status.onEndOfBook = self._orig_onEndOfBook
        self._orig_onEndOfBook = nil
    end

    self.read_report:on_close_document()
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

function M:detectWeReadBook()
    if not self.ui.document then
        return nil
    end
    local file = self.ui.document.file
    if not file then
        return nil
    end
    local books = self.settings:get("books", {})

    -- 1) Exact content-file index match (flat library title.epub etc.)
    for book_id, book in pairs(books) do
        if type(book) == "table" then
            if file == book.cached_file then
                return book_id
            end
            if type(book.cached_chapters) == "table" then
                for _uid, chapter_path in pairs(book.cached_chapters) do
                    if chapter_path == file then
                        return book_id
                    end
                end
            end
        end
    end

    -- 2) Legacy/nested content still living under a bookId sidecar/content dir.
    for book_id, book in pairs(books) do
        if type(book) == "table" then
            local dir = Content.book_resolved_dir(
                self.settings, book_id, book):gsub("/+$", "") .. "/"
            if file:sub(1, #dir) == dir then
                return book_id
            end
        end
    end

    -- 3) Legacy path layout only: <download>/<book_id>/file.epub
    local prefix = self.settings.cache_dir:gsub("/+$", "") .. "/"
    if file:sub(1, #prefix) == prefix then
        local rest = file:sub(#prefix + 1)
        local nested_id = rest:match("^([^/]+)/")
        if nested_id and books[nested_id] then
            return nested_id
        end
        if nested_id then
            return nested_id
        end
    end

    -- 4) Opened a file under metadata tree (rare; MP html etc.)
    local meta_root = self.settings.meta_dir
    if type(meta_root) == "string" and meta_root ~= "" then
        local meta_prefix = meta_root:gsub("/+$", "") .. "/"
        if file:sub(1, #meta_prefix) == meta_prefix then
            local rest = file:sub(#meta_prefix + 1)
            return rest:match("^([^/]+)")
        end
    end
    return nil
end

function M:ensureChaptersLoaded(book)
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
function M:getChapterInfoFromFile(book, file_path)
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

function M:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

return M
