-- Annotation visibility and thought-link interaction UI.
local Annotations = require("weread.lib.annotations")
local Content = require("weread.lib.content")
local DownloadDialog = require("weread.ui.download_dialog")
local Event = require("ui/event")
local logger = require("weread.lib.logger")
local ThoughtDB = require("weread.lib.thought_db")
local ThoughtPopup = require("weread.ui.thought_popup")
local time = require("ui/time")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local thought_perf = PluginUtil.thought_perf

local M = {}

-- Hard ceiling for the per-session thought cache, cleared on book close.
local THOUGHT_PAGE_CACHE_MAX = 300

-- Runtime CSS that hides underlines baked into cached EPUBs.
-- Applied as an appended stylesheet (not persisted to the book sidecar) so it
-- acts as a global display preference without mutating downloaded files.
-- NOTE: only tweak visual/metric properties (border, padding, font-size). Never
-- use display/white-space here — changing those marks the built DOM stale and
-- makes ReaderRolling repeatedly prompt for a full document reload.
local ANNOTATION_HIDE_CSS =
    ".wr-underline{border-bottom:0 !important;padding-bottom:0 !important;} "
    .. ".wr-thought-link{pointer-events:none !important;text-decoration:none !important;color:inherit !important;}"

-- Apply the initial hidden state before KOReader renders the document. Doing
-- this from onReaderReady starts partial rerendering; its seamless reload then
-- creates a new plugin instance and repeats the same rerender forever.
function M:onReadSettings()
    if not self.ui or not self.ui.document or not self:detectWeReadBook() then
        return
    end
    if self.settings:get("cache").show_annotations ~= false then
        return
    end
    local typeset = self.ui.typeset
    if not typeset or not typeset.css then
        logger.warn("onReadSettings: typeset stylesheet unavailable")
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
        logger.warn("initial annotation visibility failed:", err)
    end
end

-- Reapply the current annotation visibility preference to the open WeRead book.
-- Show=true reapplies the base stylesheet + user tweaks (revealing baked-in
-- underlines); show=false appends ANNOTATION_HIDE_CSS on top. Triggers a reflow.
function M:applyAnnotationVisibility()
    if not self.ui or not self.ui.document then
        return
    end
    local show = self.settings:get("cache").show_annotations ~= false
    if self._xpointer_overlay then
        self._xpointer_overlay:setEnabled(show)
        UIManager:setDirty(self.dialog, "ui")
    end
    if not self:detectWeReadBook() then
        return
    end
    local typeset = self.ui.typeset
    if not typeset or not typeset.css then
        logger.warn("applyAnnotationVisibility: typeset stylesheet unavailable")
        return
    end
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
        logger.warn("applyAnnotationVisibility failed:", err)
    end
end

function M:toggleAnnotationVisibility()
    local cache = self.settings:get("cache")
    cache.show_annotations = not (cache.show_annotations ~= false)
    self.settings:set("cache", cache)
    self.settings:flush()
    if not cache.show_annotations then
        ThoughtPopup.closeVisible()
        self._thought_popup_open = nil
    end
    self:applyAnnotationVisibility()
    self:showTransientInfo(cache.show_annotations
        and _("Underlines and thoughts shown")
        or _("Underlines and thoughts hidden"), 1)
    return true
end

function M:onToggleWeReadAnnotations()
    return self:toggleAnnotationVisibility()
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

-- Current SQLite/JSON-era anchors use #wrthought-BOOK-CHAPTER-START-END.
-- Earlier HTML-embedded footnotes used #thought_CHAPTER_START_END.
local function isThoughtHref(href)
    return type(href) == "string"
        and (href:find("wrthought%-") ~= nil
            or href:match("#?thought_.+_%d+_%d+") ~= nil)
end

-- Hide our thought anchors from KOReader's link hit-testing when:
--   1) annotations are hidden, or
--   2) edge-tap ignore is on and the tap is in the left/right page-turn zone.
--
-- crengine ignores CSS pointer-events for link detection, so without this a tap
-- on a thought underline is swallowed by ReaderLink (it follows a #wrthought
-- or legacy #thought_ anchor)
-- instead of turning the page.
--
-- Wrap onTap itself and return false for ignored thoughts,
-- so the event continues to propagate to the page-turn zone (honoring the user's
-- tap zones / RTL). Only own anchors are affected.
function M:_installLinkFilter()
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
        if not isThoughtHref(href) then
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
            -- detect the link with the *original* getter and suppress only our
            -- current or legacy thought anchors.
            if plugin.settings:get("cache").show_annotations == false
                or isPageTurnEdgeTap(plugin, ges) then
                local link = plugin._orig_getLinkFromGes(link_self, ges)
                if link then
                    local href = plugin:_linkHref(link)
                    if isThoughtHref(href) then
                        return false
                    end
                end
            end
            return plugin._orig_onTap(link_self, arg, ges)
        end
    end
end

function M:_removeLinkFilter()
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

function M:_teardownThoughtInterception()
    if self._thought_interception_setup and self.ui then
        self.ui:unRegisterTouchZones({
            { id = "weread_thought_tap", overrides = { "tap_link" } },
        })
        self._thought_interception_setup = nil
    end
    self:_removeLinkFilter()
    -- Document boundary: drop the pooled popup entirely. closeVisible() would
    -- keep the pooled widget and its page/piece/layout caches (~10+ MB of
    -- bitmaps) alive for the whole KOReader session; cleanup() frees them.
    ThoughtPopup.cleanup()
    if self._thought_refresh_request then
        local progress_dialog = self._thought_refresh_request.progress_dialog
        self._thought_refresh_request = nil
        if progress_dialog then
            progress_dialog:close()
        end
    end
    if self._thought_db then
        ThoughtDB.close(self._thought_db)
        self._thought_db = nil
        self._thought_db_dir = nil
        self._thought_db_book_id = nil
    end
    self._thought_popup_open = nil
    self._current_thought_popup = nil
    self._thought_page_cache = nil
    self._thought_page_cache_n = nil
    self._thought_highlight_active = nil
    self._current_weread_book_id = nil
end

function M:_setupThoughtInterception()
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

function M:_clearThoughtHighlight(document)
    if not self._thought_highlight_active then
        return
    end
    pcall(function()
        document:highlightXPointer()
    end)
    self._thought_highlight_active = nil
    UIManager:setDirty(self.dialog, "ui")
end

function M:_showThoughtPopup(pages, link, session_gen, tap_started)
    local show_started = time.now()
    if session_gen and session_gen ~= self._reader_session_gen then
        self._thought_popup_open = nil
        return
    end
    if type(pages) ~= "table" or #pages == 0 then
        self._thought_popup_open = nil
        return
    end

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

    local popup_started = time.now()
    local ok_params, params = pcall(function()
        return self:_thoughtPopupLayoutParams()
    end)
    params = ok_params and params or nil
    local ok, popup = pcall(function()
        return ThoughtPopup.show({
            pages = pages,
            height_ratio = tonumber(self.settings:get("thought_popup").height_ratio) or 0.62,
            position = self.settings:get("thought_popup").position or "bottom",
            dialog = self.dialog,
            doc_font_name = params and params.doc_font_name,
            doc_font_size = params and params.doc_font_size,
            doc_margins = params and params.doc_margins,
            close_callback = function()
                self._thought_popup_open = nil
                self._current_thought_popup = nil
                if self._thought_highlight_active then
                    self._thought_highlight_active = nil
                    document:highlightXPointer()
                    UIManager:setDirty(self.dialog, "ui")
                end
            end,
        })
    end)
    thought_perf("popup_show", popup_started, "ok=", tostring(ok),
        "pages=", tostring(#pages))

    if not ok then
        logger.warn("thought popup failed:", popup)
        self._thought_popup_open = nil
        self:_clearThoughtHighlight(document)
        return
    end

    self._current_thought_popup = popup
    thought_perf("show_pipeline", show_started, "pages=", tostring(#pages))
    if tap_started then
        thought_perf("tap_to_popup_return", tap_started, "pages=", tostring(#pages))
    end
end

-- Reader font/layout preferences for the thought popup so it matches the book
-- text. Returns nil when unavailable; every access is guarded and callers fall
-- back to the popup's built-in defaults.
function M:_thoughtPopupLayoutParams()
    if not self.ui or not self.ui.document then
        return nil
    end
    local document = self.ui.document
    local Screen = require("device").screen

    local font_face = self.ui.font and self.ui.font.font_face
    if not font_face then
        font_face = G_reader_settings:readSetting("cre_font")
    end

    local thought_popup = self.settings:get("thought_popup")
    local font_size = thought_popup.font_size
    local font_size_scaled
    if font_size then
        font_size_scaled = Screen:scaleBySize(font_size)
    else
        local relative = tonumber(thought_popup.font_size_relative) or -2
        local doc_font_size = (document.configurable and document.configurable.font_size) or 18
        font_size_scaled = Screen:scaleBySize(doc_font_size) + relative
    end

    local ok, margins = pcall(function()
        return document:getPageMargins()
    end)

    return {
        doc_font_name = font_face,
        doc_font_size = font_size_scaled,
        doc_margins = ok and margins or nil,
    }
end

-- Recursively pull a thought anchor href out of a KOReader link object.
-- The link's shape differs between engines and even between tap locations inside
-- the same anchor, so scan common fields first, then a shallow crawl.
function M:_linkHref(link)
    local seen = {}
    local function extract(value, depth)
        if depth > 4 or value == nil then
            return nil
        end
        if type(value) == "string" then
            return value:match("(#wrthought%-[%w%._%-]+)")
                or value:match("(wrthought%-[%w%._%-]+)")
                or value:match("(#thought_[%w%._%-]+)")
                or value:match("(thought_[%w%._%-]+)")
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
function M:_parseThoughtHref(href)
    if type(href) ~= "string" then
        return nil
    end

    local legacy_anchor = href:match("#?(thought_[%w%._%-]+)")
    if legacy_anchor then
        local chapter_uid, start_pos, end_pos =
            legacy_anchor:match("^thought_(.-)_(%d+)_(%d+)$")
        if chapter_uid and start_pos and end_pos
            and self._current_weread_book_id then
            return {
                book_id = self._current_weread_book_id,
                chapter_uid = chapter_uid,
                range = start_pos .. "-" .. end_pos,
                legacy_html = true,
            }
        end
    end

    local anchor = href:match("#?(wrthought%-[%w%._%-]+)")
    if not anchor then
        return nil
    end
    local book_id, chapter_uid, start_pos, end_pos =
        anchor:match("^wrthought%-([^%-]+)%-([^%-]+)%-(%d+)%-(%d+)$")
    if not (book_id and chapter_uid and start_pos and end_pos) then
        logger.warn("unparseable thought anchor:", anchor)
        return nil
    end
    return {
        book_id = book_id,
        chapter_uid = chapter_uid,
        range = start_pos .. "-" .. end_pos,
    }
end

function M:_ensureThoughtDB(book_id)
    if self._thought_db and self._thought_db_book_id == book_id then
        return self._thought_db
    end

    local books = self.settings:get("books", {})
    local book = books[book_id]
    if not book then
        return nil
    end

    local book_dir = Content.book_resolved_dir(self.settings, book_id, book)
    if self._thought_db_dir == book_dir and self._thought_db then
        return self._thought_db
    end

    local db_open_started = time.now()
    if self._thought_db then
        ThoughtDB.close(self._thought_db)
    end
    self._thought_db = ThoughtDB.open(book_dir)
    self._thought_db_dir = self._thought_db and book_dir or nil
    self._thought_db_book_id = self._thought_db and book_id or nil
    thought_perf("sqlite_open", db_open_started,
        "ok=", tostring(self._thought_db ~= nil))
    return self._thought_db
end

-- Load the tapped range as native-dialog pages from the normalized SQLite
-- table. There is intentionally no JSON or HTML compatibility path: this schema
-- predates release, so a missing row triggers an automatic chapter/full-book
-- thought repair below.
function M:_buildThoughtPagesFromHref(href)
    local info = self:_parseThoughtHref(href)
    if not info then
        return nil
    end

    local db = self:_ensureThoughtDB(info.book_id)
    if db then
        local query_started = time.now()
        local items = ThoughtDB.getReviewItems(db, info.chapter_uid, info.range)
        thought_perf("sqlite_range_query", query_started,
            "items=", tostring(type(items) == "table" and #items or 0))
        if type(items) == "table" and #items > 0 then
            return items
        end
    end

    return nil, info
end

function M:_queueThoughtPopup(pages, link, tap_started)
    if type(pages) ~= "table" or #pages == 0 then
        return true
    end

    -- Guard against a stale flag: if we believe a popup is open but it is not
    -- actually on screen, reset instead of swallowing every tap forever.
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
        self:_showThoughtPopup(pages, link, session_gen, tap_started)
    end)
    return true
end

-- A link from an older HTML/JSON cache may exist while the normalized SQLite
-- rows do not. Repair the whole currently-open artifact: one chapter for a
-- single-chapter EPUB, or every chapter for a combined full-book EPUB.
function M:_downloadMissingThought(info, href, link, tap_started)
    if self._thought_refresh_request then
        return true
    end
    if not self:requireLogin(false, true) then
        return true
    end

    local document = self.ui and self.ui.document
    local books = self.settings:get("books", {})
    local book = books[info.book_id]
    local catalog = book and self:ensureChaptersLoaded(book)
    if not book or type(catalog) ~= "table" or #catalog == 0 then
        self:showInfo(_("Thought cache error. Please re-download this book with underlines and thoughts."))
        return true
    end

    local file_path = document and document.file
    local _current_idx, current_chapter, is_full_book =
        self:getChapterInfoFromFile(book, file_path)
    local chapters
    if is_full_book then
        chapters = {}
        for _, chapter in ipairs(catalog) do
            if chapter.chapterUid ~= nil then
                chapters[#chapters + 1] = chapter
            end
        end
    else
        if not current_chapter then
            for _, chapter in ipairs(catalog) do
                if tostring(chapter.chapterUid) == tostring(info.chapter_uid) then
                    current_chapter = chapter
                    break
                end
            end
        end
        chapters = current_chapter and { current_chapter } or nil
    end
    if not chapters or #chapters == 0 then
        self:showInfo(_("Thought cache error. Please re-download this book with underlines and thoughts."))
        return true
    end

    local request = {
        session_gen = self._reader_session_gen or 0,
        page = document and document:getCurrentPage(),
        href = href,
        book_id = info.book_id,
        target_chapter_uid = info.chapter_uid,
        target_range = info.range,
        chapters = chapters,
        chapter_index = 0,
        failed_requests = 0,
        full_book = is_full_book,
    }
    self._thought_refresh_request = request
    local progress_dialog
    progress_dialog = DownloadDialog:new{
        title = is_full_book
            and _("Local thought data is missing. Downloading full-book thoughts now…")
            or _("Local thought data is missing. Downloading chapter thoughts now…"),
        progress_max = #chapters,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        if self._thought_refresh_request == request then
                            self._thought_refresh_request = nil
                            progress_dialog:close()
                            self:showTransientInfo(_("Download cancelled"), 2)
                        end
                    end,
                },
            },
        },
    }
    request.progress_dialog = progress_dialog
    progress_dialog:show()

    local function finish_request()
        if self._thought_refresh_request == request then
            self._thought_refresh_request = nil
            if request.progress_dialog then
                request.progress_dialog:close()
                request.progress_dialog = nil
            end
        end
    end

    local function request_is_current()
        return self._thought_refresh_request == request
            and request.session_gen == self._reader_session_gen
            and self.ui and self.ui.document
    end

    local label = _("Download thoughts")
    local fail_repair
    local schedule_step
    local finish_repair
    local download_chapter
    local download_batch

    fail_repair = function(err)
        if not request_is_current() then
            finish_request()
            return
        end
        finish_request()
        logger.warn("thought repair failed:",
            "href=", href, "error=", log_error(err or "unknown"))
        self:showInfo(T(_("%1 failed:\n%2"), label, display_error(err or "unknown")))
    end

    schedule_step = function(callback, delay)
        UIManager:scheduleIn(delay or 0.1, function()
            if not request_is_current() then
                finish_request()
                return
            end
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then
                fail_repair(err)
            end
        end)
    end

    finish_repair = function()
        if not request_is_current() then
            finish_request()
            return
        end

        local db = self:_ensureThoughtDB(request.book_id)
        local pages = db and ThoughtDB.getReviewItems(
            db, request.target_chapter_uid, request.target_range
        ) or nil
        finish_request()

        self._thought_page_cache = {}
        self._thought_page_cache_n = 0
        if type(pages) ~= "table" or #pages == 0 then
            if request.failed_requests > 0 then
                self:showInfo(_("Some thoughts could not be downloaded. Tap the underline again to retry."))
            else
                self._thought_page_cache[href] = false
                self:showInfo(_("No thoughts were returned for this underline."))
            end
            return
        end
        self._thought_page_cache[href] = pages
        self._thought_page_cache_n = 1

        -- The database is fully repaired even if the reader moved elsewhere.
        -- Only auto-open the popup while the original page is still visible.
        if request.session_gen ~= self._reader_session_gen
            or self.ui.document:getCurrentPage() ~= request.page then
            return
        end
        self:_queueThoughtPopup(pages, link, tap_started)
    end

    download_batch = function()
        if request.batch_index > #request.batches then
            request.progress_dialog:setTitle(
                T(_("Processing underlines and thoughts · chapter %1/%2"),
                    tostring(request.chapter_index), tostring(#request.chapters))
            )
            request.progress_dialog:reportProgress(request.chapter_index - 0.05)
            local db = self:_ensureThoughtDB(request.book_id)
            if not db or not ThoughtDB.putReviews(
                db, request.chapter.chapterUid, request.reviews
            ) then
                fail_repair("failed to write thought database")
                return
            end
            request.progress_dialog:reportProgress(request.chapter_index)
            schedule_step(download_chapter, 0.1)
            return
        end

        local batch_index = request.batch_index
        local batch_total = #request.batches
        local fractional = request.chapter_index - 0.85
            + 0.7 * batch_index / math.max(1, batch_total)
        request.progress_dialog:setTitle(
            T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
                tostring(batch_index), tostring(batch_total),
                tostring(request.chapter_index), tostring(#request.chapters))
        )
        request.progress_dialog:reportProgress(fractional)

        local batch_started = time.now()
        local ok, result, err = self.client:get_chapter_reviews_batch(
            request.book_id, request.chapter.chapterUid,
            request.batches[batch_index]
        )
        thought_perf("thought_repair_batch", batch_started,
            "chapter=", tostring(request.chapter_index) .. "/" .. tostring(#request.chapters),
            "batch=", tostring(batch_index) .. "/" .. tostring(batch_total),
            "ok=", tostring(ok), "retry=", tostring(request.batch_retry or 0))
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            for _, review in ipairs(result.reviews) do
                request.reviews[#request.reviews + 1] = review
            end
            request.batch_retry = 0
            request.batch_index = request.batch_index + 1
        else
            request.batch_retry = (request.batch_retry or 0) + 1
            if request.batch_retry <= 2 then
                request.progress_dialog:setTitle(
                    T(_("Retrying thoughts %1/%2 · attempt %3"),
                        tostring(batch_index), tostring(batch_total),
                        tostring(request.batch_retry))
                )
                schedule_step(download_batch, 0.6 * request.batch_retry)
                return
            end
            request.failed_requests = request.failed_requests + 1
            logger.warn("thought repair batch skipped after retries:",
                "chapter_uid=", tostring(request.chapter.chapterUid),
                "batch=", tostring(request.batch_index),
                "error=", log_error(err or "unknown"))
            request.batch_retry = 0
            request.batch_index = request.batch_index + 1
        end
        schedule_step(download_batch, 0.3)
    end

    download_chapter = function()
        request.chapter_index = request.chapter_index + 1
        if request.chapter_index > #request.chapters then
            finish_repair()
            return
        end

        request.chapter = request.chapters[request.chapter_index]
        request.progress_dialog:setTitle(T(_("Downloading underlines · chapter %1/%2"),
            tostring(request.chapter_index), tostring(#request.chapters)))
        request.progress_dialog:reportProgress(request.chapter_index - 0.85)

        local underlines_started = time.now()
        local ok, underlines, err = self.client:get_chapter_underlines(
            request.book_id, request.chapter.chapterUid
        )
        thought_perf("thought_repair_underlines", underlines_started,
            "chapter=", tostring(request.chapter_index) .. "/" .. tostring(#request.chapters),
            "ok=", tostring(ok))
        if not ok or type(underlines) ~= "table" then
            request.failed_requests = request.failed_requests + 1
            logger.warn("thought repair chapter skipped:",
                "chapter_uid=", tostring(request.chapter.chapterUid),
                "error=", log_error(err or "unknown"))
            request.progress_dialog:reportProgress(request.chapter_index)
            schedule_step(download_chapter, 0.1)
            return
        end

        local ranges = {}
        local seen_ranges = {}
        for _, underline in ipairs(underlines.underlines or {}) do
            if type(underline.range) == "string" and underline.range ~= ""
                and not seen_ranges[underline.range] then
                seen_ranges[underline.range] = true
                ranges[#ranges + 1] = underline.range
            end
        end
        request.reviews = {}
        request.batches = self.client:build_chapter_review_batches(ranges)
        request.batch_index = 1
        request.batch_retry = 0
        if #request.batches == 0 then
            request.progress_dialog:setTitle(
                T(_("Processing underlines and thoughts · chapter %1/%2"),
                    tostring(request.chapter_index), tostring(#request.chapters))
            )
            request.progress_dialog:reportProgress(request.chapter_index - 0.05)
            local db = self:_ensureThoughtDB(request.book_id)
            if not db or not ThoughtDB.putReviews(
                db, request.chapter.chapterUid, {}
            ) then
                fail_repair("failed to write thought database")
                return
            end
            request.progress_dialog:reportProgress(request.chapter_index)
            schedule_step(download_chapter, 0.1)
        else
            schedule_step(download_batch, 0.1)
        end
    end

    local scheduled = self:runOnlineTask(label, function()
        if not request_is_current() then
            finish_request()
            return
        end
        schedule_step(function()
            if request.full_book then
                if self._thought_db then
                    ThoughtDB.close(self._thought_db)
                    self._thought_db = nil
                    self._thought_db_dir = nil
                    self._thought_db_book_id = nil
                end
                local book_dir = Content.book_resolved_dir(
                    self.settings, request.book_id, book
                )
                ThoughtDB.remove_db(book_dir)
            end
            download_chapter()
        end, 0.1)
    end)

    if not scheduled then
        finish_request()
    end
    return true
end

function M:_onThoughtTap(ges)
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
    if not isThoughtHref(href) then
        -- Some other EPUB link (footnote, TOC, external) → let KOReader handle it.
        return false
    end

    -- Annotations hidden: _installLinkFilter already made getLinkFromGes return nil
    -- for our anchors, so we normally return above before reaching here. Kept as a
    -- defensive fall-through in case the filter is not active.
    if self.settings:get("cache").show_annotations == false then
        return false
    end

    -- Cache native pages by href (stable, page-independent).
    self._thought_page_cache = self._thought_page_cache or {}
    local pages = self._thought_page_cache[href]
    local was_cached = pages ~= nil
    local info
    if pages == nil then
        pages, info = self:_buildThoughtPagesFromHref(href)
        if pages then
            self._thought_page_cache_n = (self._thought_page_cache_n or 0) + 1
            if self._thought_page_cache_n > THOUGHT_PAGE_CACHE_MAX then
                self._thought_page_cache = {}
                self._thought_page_cache_n = 1
            end
            self._thought_page_cache[href] = pages
        end
    end
    thought_perf("tap_resolve", tap_started, "cached=", tostring(was_cached),
        "pages=", tostring(type(pages) == "table" and #pages or 0))
    if pages == false then
        return true
    end
    if type(pages) ~= "table" or #pages == 0 then
        info = info or self:_parseThoughtHref(href)
        if info then
            return self:_downloadMissingThought(info, href, link, tap_started)
        end
        return true
    end
    return self:_queueThoughtPopup(pages, link, tap_started)
end

return M
