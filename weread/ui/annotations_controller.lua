-- Annotation visibility and thought-link interaction UI.
local Annotations = require("weread.lib.annotations")
local Content = require("weread.lib.content")
local Event = require("ui/event")
local logger = require("weread.lib.logger")
local ThoughtDB = require("weread.lib.thought_db")
local InfoMessage = require("ui/widget/infomessage")
local ThoughtPopup = require("weread.ui.thought_popup")
local time = require("ui/time")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local log_error = PluginUtil.log_error
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
    ThoughtPopup.closeVisible()
    if self._thought_db then
        ThoughtDB.close(self._thought_db)
        self._thought_db = nil
        self._thought_db_dir = nil
        self._thought_db_book_id = nil
    end
    self._thought_popup_open = nil
    self._thought_page_cache = nil
    self._thought_page_cache_n = nil
    self._current_weread_book_id = nil
    -- Cancel any in-flight silent chapter thought prefetch.
    if self._chapter_thought_prefetch then
        self._chapter_thought_prefetch.cancelled = true
        self._chapter_thought_prefetch = nil
    end
    self._thought_inflight = nil
    self._thought_read_max_page = nil
    self._thought_prefetch_idle_gen = nil
    self:_dismissThoughtLoading()
end

function M:_dismissThoughtLoading()
    if self._thought_loading_msg then
        UIManager:close(self._thought_loading_msg)
        self._thought_loading_msg = nil
    end
end

function M:_showThoughtLoading()
    if self._thought_loading_msg then
        return
    end
    self._thought_loading_msg = InfoMessage:new{
        text = _("Loading thoughts…"),
        dismissable = false,
    }
    UIManager:show(self._thought_loading_msg)
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

function M:_showThoughtPopup(pages, link, session_gen, tap_started)
    local show_started = time.now()
    if session_gen and session_gen ~= self._reader_session_gen then
        self._thought_popup_open = nil
        self:_yieldThoughtPrefetchForReading()
        return
    end
    if type(pages) ~= "table" or #pages == 0 then
        self._thought_popup_open = nil
        self:_yieldThoughtPrefetchForReading()
        return
    end

    local popup_started = time.now()
    local ok, popup = pcall(function()
        return ThoughtPopup.show({
            pages = pages,
            height_ratio = 0.62,
            dialog = self.dialog,
            close_callback = function()
                self._thought_popup_open = nil
                self:_yieldThoughtPrefetchForReading()
            end,
        })
    end)
    thought_perf("popup_show", popup_started, "ok=", tostring(ok),
        "pages=", tostring(#pages))

    if not ok then
        logger.warn("thought popup failed:", popup)
        self._thought_popup_open = nil
        self:_yieldThoughtPrefetchForReading()
        return
    end

    thought_perf("show_pipeline", show_started, "pages=", tostring(#pages))
    if tap_started then
        thought_perf("tap_to_popup_return", tap_started, "pages=", tostring(#pages))
    end
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
    local book = books[book_id] or books[tostring(book_id)]
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

-- Load the tapped range from SQLite. Missing rows trigger an on-demand
-- single-range fetch in _downloadMissingThought.
function M:_buildThoughtPagesFromHref(href)
    local info = self:_parseThoughtHref(href)
    if not info then
        return nil
    end

    local db = self:_ensureThoughtDB(info.book_id)
    if db then
        local query_started = time.now()
        local items = ThoughtDB.getReviewItems(db, info.chapter_uid, info.range)
        if type(items) == "table" and #items > 0 then
            thought_perf("sqlite_range_query", query_started,
                "items=", tostring(#items))
            return items
        end
        local fetched = ThoughtDB.isRangeFetched(db, info.chapter_uid, info.range)
        thought_perf("sqlite_range_query", query_started,
            "items=0", "fetched=", tostring(fetched))
        if fetched then
            return false, info
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
            self:_yieldThoughtPrefetchForReading()
            return
        end
        if not self.ui or not self.ui.document then
            self._thought_popup_open = nil
            self:_yieldThoughtPrefetchForReading()
            return
        end
        self:_showThoughtPopup(pages, link, session_gen, tap_started)
    end)
    return true
end

-- Missing local rows: fetch only the tapped range (low rate-limit risk).
-- On success, silently prefetch the rest of the chapter with backoff + jitter.
function M:_downloadMissingThought(info, href, link, tap_started)
    if not self:requireLogin(false, true) then
        return true
    end

    if not self:isNetworkOnline() then
        self:showOffline(_("Download thoughts"))
        return true
    end

    local chapter_uid = tonumber(info.chapter_uid) or info.chapter_uid
    local range = info.range
    local book_id = info.book_id
    local fetch_key = self:_thoughtFetchKey(book_id, chapter_uid, range)

    -- Drop this range from silent prefetch so the tap fetch is the only request.
    self:_removePrefetchRange(book_id, chapter_uid, range)

    -- Coalesce duplicate taps for the same range.
    self._thought_inflight = self._thought_inflight or {}
    local inflight = self._thought_inflight[fetch_key]
    if inflight then
        inflight.waiters[#inflight.waiters + 1] = {
            href = href,
            link = link,
            tap_started = tap_started,
        }
        return true
    end

    local batch = {{
        range = range,
        maxIdx = 0,
        count = 30,
        synckey = 0,
    }}

    local label = _("Download thoughts")
    local max_attempts = 3
    local session_gen = self._reader_session_gen or 0

    local function finish_success(items, reviews)
        self._thought_inflight[fetch_key] = nil
        self:_dismissThoughtLoading()

        self._thought_page_cache = self._thought_page_cache or {}
        self._thought_page_cache[href] = items
        self:_queueThoughtPopup(items, link, tap_started)

        for _, w in ipairs(inflight.waiters) do
            self._thought_page_cache[w.href] = items
            self:_queueThoughtPopup(items, w.link, w.tap_started)
        end

        -- Persist before prefetch can resume so this range is not requested again.
        local db = self:_ensureThoughtDB(book_id)
        if db then
            pcall(ThoughtDB.putReviewRanges, db, chapter_uid, reviews, { range })
        end

        -- Advance the forward cursor only. Stay paused until the popup closes.
        self:_scheduleChapterThoughtPrefetch(book_id, chapter_uid, range)
    end

    local function finish_empty()
        self._thought_inflight[fetch_key] = nil
        self:_dismissThoughtLoading()
        self._thought_page_cache = self._thought_page_cache or {}
        self._thought_page_cache[href] = false
        for _, w in ipairs(inflight.waiters) do
            self._thought_page_cache[w.href] = false
        end
        local db = self:_ensureThoughtDB(book_id)
        if db then
            pcall(ThoughtDB.markRangesFetched, db, chapter_uid, { range })
        end
        self:showTransientInfo(_("No thoughts were returned for this underline."), 2)
        self:_scheduleChapterThoughtPrefetch(book_id, chapter_uid, range)
        self:_yieldThoughtPrefetchForReading()
    end

    local function finish_error()
        self._thought_inflight[fetch_key] = nil
        self:_dismissThoughtLoading()
        self:showTransientInfo(
            _("Some thoughts could not be downloaded. Tap the underline again to retry."),
            2
        )
        self:_yieldThoughtPrefetchForReading()
    end

    inflight = { waiters = {} }
    self._thought_inflight[fetch_key] = inflight
    self:_showThoughtLoading()

    local function attempt_fetch(attempt)
        if session_gen ~= (self._reader_session_gen or 0) then
            self._thought_inflight[fetch_key] = nil
            self:_dismissThoughtLoading()
            self:_yieldThoughtPrefetchForReading()
            return
        end
        if not self:isNetworkOnline() then
            self._thought_inflight[fetch_key] = nil
            self:_dismissThoughtLoading()
            self:showOffline(label)
            self:_yieldThoughtPrefetchForReading()
            return
        end

        local ok, result, err = self.client:get_chapter_reviews_batch(
            book_id,
            chapter_uid,
            batch,
            { timeout = 1.5 }
        )

        if not ok then
            logger.warn(
                "on-demand thought fetch failed:",
                "attempt=", attempt,
                "err=", log_error(err or "unknown")
            )
            if attempt < max_attempts then
                local delay = math.random() * (0.6 * (2 ^ (attempt - 1)))
                if delay < 0.25 then
                    delay = 0.25
                end
                UIManager:scheduleIn(delay, function()
                    attempt_fetch(attempt + 1)
                end)
                return
            end
            finish_error()
            return
        end

        local reviews = result and result.reviews or {}
        if type(reviews) ~= "table" or #reviews == 0 then
            finish_empty()
            return
        end

        local items = {}
        for _, review in ipairs(reviews) do
            for _, item in ipairs(Annotations.buildThoughtPopupItems(review)) do
                items[#items + 1] = item
            end
        end
        if #items == 0 then
            finish_empty()
            return
        end

        finish_success(items, reviews)
    end

    self:runOnlineTask(label, function()
        attempt_fetch(1)
    end)

    return true
end

-- Silent thought prefetch: later ranges after the last tap, in reading order.

local function thoughtPrefetchDelay(base_seconds, attempt, cap_seconds)
    local exp = base_seconds * (2 ^ math.max(0, attempt))
    if exp > cap_seconds then
        exp = cap_seconds
    end
    return math.random() * exp
end

local function thoughtPrefetchBatchGap()
    -- Slightly longer gaps so the UI thread is free between blocking HTTP calls.
    return 0.8 + math.random() * 0.7
end

function M:_thoughtFetchInFlight()
    local inflight = self._thought_inflight
    return type(inflight) == "table" and next(inflight) ~= nil
end

-- True while a thought popup is up or a tap-fetch is still running.
-- Prefetch must stay paused so a new HTTP batch cannot start under the tap.
function M:_thoughtPrefetchShouldStayPaused()
    if self:_thoughtFetchInFlight() then
        return true
    end
    if not self._thought_popup_open then
        return false
    end
    if ThoughtPopup.isShowing() then
        return true
    end
    self._thought_popup_open = nil
    return false
end

-- Pause blocking prefetch and only resume after the reader has been idle
-- briefly. Used on page turns, underline taps, and thought-popup close.
function M:_yieldThoughtPrefetchForReading()
    local job = self._chapter_thought_prefetch
    if not job or job.cancelled then
        return
    end
    job.paused = true
    local token = (self._thought_prefetch_idle_gen or 0) + 1
    self._thought_prefetch_idle_gen = token
    UIManager:scheduleIn(1.2, function()
        if self._thought_prefetch_idle_gen ~= token then
            return
        end
        job = self._chapter_thought_prefetch
        if not job or job.cancelled then
            return
        end
        if self:_thoughtPrefetchShouldStayPaused() then
            return
        end
        job.paused = false
        if job.batches then
            self:_stepChapterThoughtPrefetch(job)
        else
            self:_runChapterThoughtPrefetch(job)
        end
    end)
end

function M:_removePrefetchRange(book_id, chapter_uid, range)
    local job = self._chapter_thought_prefetch
    if not job or job.cancelled or not job.batches then
        return
    end
    if tostring(job.book_id) ~= tostring(book_id) then
        return
    end
    if tostring(job.chapter_uid) ~= tostring(chapter_uid) then
        return
    end
    if type(range) ~= "string" or range == "" then
        return
    end

    local start_i = job.batch_index or 1
    for i = #job.batches, start_i, -1 do
        local batch = job.batches[i]
        if type(batch) == "table" then
            for j = #batch, 1, -1 do
                if type(batch[j]) == "table" and batch[j].range == range then
                    table.remove(batch, j)
                end
            end
            if #batch == 0 then
                table.remove(job.batches, i)
            end
        end
    end
end

local function rangeStart(range)
    return tonumber((tostring(range or ""):match("^(%d+)%-")))
end

local function currentDocumentPage(plugin)
    local page
    pcall(function()
        if plugin.ui and plugin.ui.document and plugin.ui.document.getCurrentPage then
            page = plugin.ui.document:getCurrentPage()
        end
    end)
    return page
end

-- True/false for whether the current page still has this chapter's thought
-- links, or already shows another chapter's links (full-book EPUB boundary).
local function currentPageThoughtChapterFlags(plugin, book_id, chapter_uid)
    local document = plugin.ui and plugin.ui.document
    if not document or type(document.getPageLinks) ~= "function" then
        return false, false
    end
    local page = currentDocumentPage(plugin)
    if not page then
        return false, false
    end
    local links
    pcall(function()
        links = document:getPageLinks(page)
    end)
    if type(links) ~= "table" then
        return false, false
    end
    local same, other = false, false
    local book_str = tostring(book_id)
    local chapter_str = tostring(chapter_uid)
    for _, link in ipairs(links) do
        local info = plugin:_parseThoughtHref(plugin:_linkHref(link))
        if info and tostring(info.book_id) == book_str then
            if tostring(info.chapter_uid) == chapter_str then
                same = true
            else
                other = true
            end
        end
    end
    return same, other
end

function M:_noteThoughtReadPage()
    local page = currentDocumentPage(self)
    if page then
        local max_page = self._thought_read_max_page or page
        if page > max_page then
            max_page = page
        end
        self._thought_read_max_page = max_page
    end
    return page
end

function M:_trimPrefetchBeforeCursor(job)
    if not job or type(job.batches) ~= "table" then
        return
    end
    local cursor = job.after_start or -1
    local start_i = job.batch_index or 1
    for i = #job.batches, start_i, -1 do
        local batch = job.batches[i]
        if type(batch) == "table" then
            for j = #batch, 1, -1 do
                local start = rangeStart(batch[j] and batch[j].range)
                if not start or start <= cursor then
                    table.remove(batch, j)
                end
            end
            if #batch == 0 then
                table.remove(job.batches, i)
            end
        end
    end
end

function M:_nextChapterForThoughtPrefetch(book_id, chapter_uid)
    local books = self.settings:get("books", {})
    local book = books[tostring(book_id)] or books[book_id]
    if not book or type(self.ensureChaptersLoaded) ~= "function" then
        return nil
    end
    local chapters = self:ensureChaptersLoaded(book)
    if type(chapters) ~= "table" then
        return nil
    end

    local index
    for i, chapter in ipairs(chapters) do
        if tostring(chapter.chapterUid or chapter.chapterId) == tostring(chapter_uid) then
            index = i
            break
        end
    end
    local next_chapter = index and chapters[index + 1] or nil
    if not next_chapter then
        return nil
    end

    return next_chapter.chapterUid or next_chapter.chapterId
end

function M:_shouldChainNextChapter(job)
    if not job or job.allow_chain == false then
        return false
    end
    if job.session_gen ~= (self._reader_session_gen or 0) then
        return false
    end
    if tostring(self._current_weread_book_id) ~= tostring(job.book_id) then
        return false
    end
    if not self.ui or not self.ui.document then
        return false
    end

    local page = currentDocumentPage(self)
    local max_page = self._thought_read_max_page
    if page and max_page and page + 2 < max_page then
        return false
    end

    local same_chapter, other_chapter = currentPageThoughtChapterFlags(
        self, job.book_id, job.chapter_uid
    )
    if same_chapter then
        return true
    end
    if other_chapter then
        return false
    end
    return true
end

function M:_deferChapterThoughtPrefetch(book_id, chapter_uid, skip_range)
    local session_gen = self._reader_session_gen or 0
    UIManager:scheduleIn(0.3, function()
        if session_gen ~= (self._reader_session_gen or 0) then
            return
        end
        self:_scheduleChapterThoughtPrefetch(book_id, chapter_uid, skip_range)
    end)
end

function M:_scheduleChapterThoughtPrefetch(book_id, chapter_uid, skip_range, opts)
    if not book_id or chapter_uid == nil then
        return
    end
    if not self:isNetworkConnected() then
        return
    end

    opts = opts or {}
    chapter_uid = tonumber(chapter_uid) or chapter_uid
    local after_start = -1
    if skip_range then
        after_start = rangeStart(skip_range) or -1
    elseif opts.after_start ~= nil then
        after_start = tonumber(opts.after_start) or -1
    end

    local existing = self._chapter_thought_prefetch
    if existing and not existing.cancelled
        and tostring(existing.book_id) == tostring(book_id)
        and tostring(existing.chapter_uid) == tostring(chapter_uid)
    then
        if after_start > (existing.after_start or -1) then
            existing.after_start = after_start
            existing.skip_range = skip_range
            self:_trimPrefetchBeforeCursor(existing)
        end
        if skip_range then
            self:_removePrefetchRange(book_id, chapter_uid, skip_range)
        end
        return
    end

    if existing then
        existing.cancelled = true
    end

    self:_noteThoughtReadPage()
    local job = {
        cancelled = false,
        paused = self:_thoughtPrefetchShouldStayPaused(),
        book_id = book_id,
        chapter_uid = chapter_uid,
        skip_range = skip_range,
        after_start = after_start,
        allow_chain = opts.allow_chain ~= false,
        session_gen = self._reader_session_gen or 0,
    }
    self._chapter_thought_prefetch = job

    local start_delay = opts.immediate and 0.2 or (1.0 + math.random() * 0.6)
    UIManager:scheduleIn(start_delay, function()
        self:_runChapterThoughtPrefetch(job)
    end)
end

function M:_thoughtFetchKey(book_id, chapter_uid, range)
    return tostring(book_id) .. ":"
        .. tostring(tonumber(chapter_uid) or chapter_uid) .. ":"
        .. tostring(range)
end

function M:_shouldSkipPrefetchRange(job, range)
    if type(range) ~= "string" or range == "" then
        return true
    end
    if range == job.skip_range then
        return true
    end
    local start = rangeStart(range)
    if start and start <= (job.after_start or -1) then
        return true
    end
    local key = self:_thoughtFetchKey(job.book_id, job.chapter_uid, range)
    if self._thought_inflight and self._thought_inflight[key] then
        return true
    end
    local db = self:_ensureThoughtDB(job.book_id)
    return db and ThoughtDB.isRangeFetched(db, job.chapter_uid, range) or false
end

function M:_startThoughtPrefetchBatches(job)
    local cursor = job.after_start or -1
    local ranges = {}
    for _, range in ipairs(job.collected or {}) do
        if not self:_shouldSkipPrefetchRange(job, range) then
            ranges[#ranges + 1] = range
        end
    end

    if #ranges == 0 then
        self:_finishChapterThoughtPrefetch(job)
        return
    end

    job.batches = self.client:build_chapter_review_batches(ranges)
    job.batch_index = 1
    job.batch_retry = 0
    logger.info(
        "thought prefetch start:",
        "chapter=", tostring(job.chapter_uid),
        "after=", tostring(cursor),
        "ranges=", #ranges,
        "batches=", #job.batches
    )
    self:_stepChapterThoughtPrefetch(job)
end

function M:_runChapterThoughtPrefetch(job)
    if not job or job.cancelled then
        return
    end
    if job.session_gen ~= (self._reader_session_gen or 0) then
        job.cancelled = true
        return
    end
    if self._chapter_thought_prefetch ~= job then
        return
    end
    if job.paused then
        return
    end
    if self:_thoughtPrefetchShouldStayPaused() then
        job.paused = true
        return
    end
    if not self:isNetworkConnected() then
        return
    end

    if job.batches then
        self:_stepChapterThoughtPrefetch(job)
        return
    end

    local db = self:_ensureThoughtDB(job.book_id)
    job.collected = db and ThoughtDB.getUnderlineRanges(db, job.chapter_uid) or {}
    self:_startThoughtPrefetchBatches(job)
end

function M:_finishChapterThoughtPrefetch(job)
    logger.info(
        "thought prefetch chapter done:",
        "chapter=", tostring(job.chapter_uid),
        "allow_chain=", tostring(job.allow_chain)
    )
    if self._chapter_thought_prefetch == job then
        self._chapter_thought_prefetch = nil
    end
    if job.allow_chain == false then
        return
    end
    if not self:_shouldChainNextChapter(job) then
        return
    end

    local next_uid = self:_nextChapterForThoughtPrefetch(job.book_id, job.chapter_uid)
    if next_uid == nil then
        return
    end

    local db = self:_ensureThoughtDB(job.book_id)
    local db_ranges = db and ThoughtDB.getUnderlineRanges(db, next_uid)
    if type(db_ranges) ~= "table" or #db_ranges == 0 then
        logger.info("thought prefetch skip next chapter: no underline catalog",
            tostring(next_uid))
        return
    end

    logger.info("thought prefetch chain next chapter:", tostring(next_uid))
    self:_scheduleChapterThoughtPrefetch(
        job.book_id, next_uid, nil, {
            allow_chain = false,
            immediate = true,
        }
    )
end

function M:_stepChapterThoughtPrefetch(job)
    if not job or job.cancelled then
        return
    end
    if job.session_gen ~= (self._reader_session_gen or 0) then
        job.cancelled = true
        return
    end
    if self._chapter_thought_prefetch ~= job then
        return
    end
    if job.paused then
        return
    end
    if self:_thoughtPrefetchShouldStayPaused() then
        job.paused = true
        return
    end
    if not self:isNetworkConnected() then
        return
    end

    if not job.batches or job.batch_index > #job.batches then
        self:_finishChapterThoughtPrefetch(job)
        return
    end

    local batch = job.batches[job.batch_index]
    if type(batch) == "table" then
        for index = #batch, 1, -1 do
            local item = batch[index]
            if self:_shouldSkipPrefetchRange(job, type(item) == "table" and item.range or nil) then
                table.remove(batch, index)
            end
        end
    end
    if type(batch) ~= "table" or #batch == 0 then
        job.batch_index = job.batch_index + 1
        job.batch_retry = 0
        UIManager:scheduleIn(0.1, function()
            self:_stepChapterThoughtPrefetch(job)
        end)
        return
    end
    local ok, result, err = self.client:get_chapter_reviews_batch(
        job.book_id, job.chapter_uid, batch, { timeout = 1 }
    )
    if job.cancelled or self._chapter_thought_prefetch ~= job or job.paused then
        return
    end

    if ok and type(result) == "table" and type(result.reviews) == "table" then
        local requested = {}
        for _, item in ipairs(batch) do
            if type(item) == "table" and type(item.range) == "string" then
                requested[#requested + 1] = item.range
            end
        end
        local db = self:_ensureThoughtDB(job.book_id)
        if db then
            pcall(ThoughtDB.putReviewRanges, db, job.chapter_uid, result.reviews, requested)
        end
        job.batch_retry = 0
        job.batch_index = job.batch_index + 1
        local gap = thoughtPrefetchBatchGap()
        UIManager:scheduleIn(gap, function()
            self:_stepChapterThoughtPrefetch(job)
        end)
        return
    end

    job.batch_retry = (job.batch_retry or 0) + 1
    if job.batch_retry <= 3 then
        local delay = thoughtPrefetchDelay(0.8, job.batch_retry - 1, 10)
        logger.warn(
            "chapter thought prefetch retry:",
            "index=", job.batch_index,
            "attempt=", job.batch_retry,
            "delay=", string.format("%.2f", delay),
            "err=", log_error(err or "unknown")
        )
        UIManager:scheduleIn(delay, function()
            self:_stepChapterThoughtPrefetch(job)
        end)
        return
    end

    logger.warn(
        "chapter thought prefetch range skipped:",
        "index=", job.batch_index,
        "err=", log_error(err or "unknown")
    )
    job.batch_retry = 0
    job.batch_index = job.batch_index + 1
    local gap = thoughtPrefetchDelay(0.5, 0, 3)
    UIManager:scheduleIn(gap, function()
        self:_stepChapterThoughtPrefetch(job)
    end)
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
        self:_yieldThoughtPrefetchForReading()
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

    -- Stop starting new prefetch HTTP under this tap. An in-flight request
    -- still cannot be aborted; the next batch waits until the popup closes
    -- (or, with no popup, until a short idle).
    self:_yieldThoughtPrefetchForReading()

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
        if pages or pages == false then
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
    self:_noteThoughtReadPage()
    if pages == false then
        self:showTransientInfo(_("No thoughts were returned for this underline."), 2)
        info = info or self:_parseThoughtHref(href)
        if info then
            self:_deferChapterThoughtPrefetch(
                info.book_id,
                tonumber(info.chapter_uid) or info.chapter_uid,
                info.range
            )
        end
        return true
    end
    if type(pages) ~= "table" or #pages == 0 then
        info = info or self:_parseThoughtHref(href)
        if info then
            return self:_downloadMissingThought(info, href, link, tap_started)
        end
        return true
    end
    -- Local hit: show first, then warm ranges after this tap.
    info = info or self:_parseThoughtHref(href)
    if info then
        self:_deferChapterThoughtPrefetch(
            info.book_id,
            tonumber(info.chapter_uid) or info.chapter_uid,
            info.range
        )
    end
    return self:_queueThoughtPopup(pages, link, tap_started)
end

return M
