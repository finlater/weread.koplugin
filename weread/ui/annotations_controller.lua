-- Annotation visibility and thought-link interaction UI.
local Annotations = require("weread.lib.annotations")
local Content = require("weread.lib.content")
local Event = require("ui/event")
local logger = require("weread.lib.logger")
local ThoughtDB = require("weread.lib.thought_db")
local ThoughtPopup = require("weread.ui.thought_popup")
local ThoughtPopupConfig = require("weread.ui.thought_popup.popup_config")
local time = require("ui/time")
local UIManager = require("ui/uimanager")

local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
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
    if self.settings:get("cache").show_annotations ~= false
        and not (self._usesUnifiedAnnotations and self:_usesUnifiedAnnotations()) then
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
        if show and self._refreshAnnotationOverlay then self:_refreshAnnotationOverlay() end
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
    if not show or (self._usesUnifiedAnnotations and self:_usesUnifiedAnnotations()) then
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
    if cache.show_annotations and self.ensureAnnotationDisplay then
        local context = self._annotation_context
        local summary = context and self:_annotationSummary(context)
        if (not summary or summary.chapters == 0)
            and self:ensureAnnotationDisplay() then
            return true
        end
    end
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

-- Truncate a thought preview to a sane length for the "Thoughts on this page"
-- list, preserving whole multi-byte characters and appending an ellipsis.
local function previewText(text, max_chars)
    text = tostring(text or ""):gsub("%s+", " ")
        :match("^%s*(.-)%s*$") or ""
    max_chars = tonumber(max_chars) or 48
    local bytes, chars = 0, 0
    while bytes < #text and chars < max_chars do
        local byte = text:byte(bytes + 1)
        local width = byte < 0x80 and 1
            or byte < 0xE0 and 2
            or byte < 0xF0 and 3
            or 4
        bytes = bytes + width
        chars = chars + 1
    end
    if bytes < #text then
        return text:sub(1, bytes) .. "…"
    end
    return text
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
        if (plugin._usesUnifiedAnnotations and plugin:_usesUnifiedAnnotations())
            or plugin.settings:get("cache").show_annotations == false
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
            if (plugin._usesUnifiedAnnotations and plugin:_usesUnifiedAnnotations())
            or plugin.settings:get("cache").show_annotations == false
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
    if self._thought_touch_interception_setup and self.ui then
        self.ui:unRegisterTouchZones({
            { id = "weread_thought_tap", overrides = { "tap_link" } },
        })
    end
    self._thought_touch_interception_setup = nil
    self._thought_interception_setup = nil
    self:_removeLinkFilter()
    self:_removeThoughtLinkInterceptor()
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
    if not self.ui or self._thought_interception_setup then
        return
    end

    -- Non-touch devices (e.g. Kindle with a 5-way controller) have no tap
    -- gesture, but ReaderLink still follows a keyboard/dispatcher "go to
    -- selected link" through onGotoLink. Intercept that final step so a
    -- selected WeRead thought anchor opens our popup instead of jumping to a
    -- non-existent document target — this is the "五向键点想法" path.
    self:_installThoughtLinkInterceptor()

    if Device:isTouchDevice() then
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
        self._thought_touch_interception_setup = true
    end
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
    local ok, popup = pcall(function()
        return ThoughtPopup.show(ThoughtPopupConfig.build(self, pages, {
            close_callback = function()
                self._thought_popup_open = nil
                self._current_thought_popup = nil
                if self._thought_highlight_active then
                    self._thought_highlight_active = nil
                    document:highlightXPointer()
                    UIManager:setDirty(self.dialog, "ui")
                end
            end,
        }))
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
-- Legacy links remain readable, but missing data always enters the unified
-- binding/matching flow; no second whole-book repair downloader remains.
function M:_downloadMissingThought()
    self:ensureAnnotationDisplay()
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
    if (self._usesUnifiedAnnotations and self:_usesUnifiedAnnotations())
        or self.settings:get("cache").show_annotations == false then
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

-- ReaderLink already knows how to select links with keyboard/dispatcher
-- actions on non-touch devices. Intercept the final follow step so a selected
-- WeRead thought anchor opens our native popup instead of jumping to the
-- anchor (which intentionally has no document target). This is the
-- "五向键点想法" path; touch devices additionally get the tap handler above.
function M:_installThoughtLinkInterceptor()
    local reader_link = self.ui and self.ui.link
    if not reader_link or type(reader_link.onGotoLink) ~= "function" then
        return false
    end
    if self._thought_link_interceptor_target == reader_link then
        return true
    end
    self:_removeThoughtLinkInterceptor()

    local plugin = self
    local original = reader_link.onGotoLink
    local wrapper
    wrapper = function(link_self, link, ...)
        local href = plugin:_linkHref(link)
        if isThoughtHref(href) then
            -- Hidden annotations must stay inert. Consume the synthetic anchor
            -- instead of letting ReaderLink jump to a non-existent target.
            if plugin.settings:get("cache", {}).show_annotations == false then
                return true
            end
            return plugin:_openThoughtLink(link, time.now())
        end
        return original(link_self, link, ...)
    end

    self._thought_link_interceptor_target = reader_link
    self._thought_link_interceptor_original = original
    self._thought_link_interceptor_wrapper = wrapper
    reader_link.onGotoLink = wrapper
    return true
end

function M:_removeThoughtLinkInterceptor()
    local reader_link = self._thought_link_interceptor_target
    local original = self._thought_link_interceptor_original
    local wrapper = self._thought_link_interceptor_wrapper
    if reader_link and original and reader_link.onGotoLink == wrapper then
        reader_link.onGotoLink = original
    end
    self._thought_link_interceptor_target = nil
    self._thought_link_interceptor_original = nil
    self._thought_link_interceptor_wrapper = nil
end

-- Collect the thought entries actually available on the current page.
-- WeRead books come in two layouts and the entry source differs:
--   * native WeRead cache books — thoughts are injected as #wrthought- HTML
--     anchors, discovered through getPageLinks();
--   * matched local books (unified annotations) — underlines are xpointer
--     overlays with NO HTML anchor; thoughts live in the unified store and are
--     discovered through the visible overlay records.
function M:_currentPageThoughtLinks()
    -- Native-book path first; if it yields anchors we are done.
    local html_links = self:_currentPageHtmlThoughtLinks()
    if #html_links > 0 then
        return html_links
    end
    -- Unified/match path: only meaningful when this book uses overlays.
    if self._usesUnifiedAnnotations and self:_usesUnifiedAnnotations() then
        return self:_currentPageUnifiedThoughtLinks()
    end
    return html_links
end

-- Native WeRead cache books: thoughts are real HTML anchors injected into the
-- chapter markup, so they surface through KOReader's document link API.
function M:_currentPageHtmlThoughtLinks()
    local document = self.ui and self.ui.document
    local reader_link = self.ui and self.ui.link
    if not document or type(document.getPageLinks) ~= "function" then
        return {}
    end

    local ok, page_links = pcall(function()
        return document:getPageLinks(true)
    end)
    if not ok or type(page_links) ~= "table" then
        logger.warn("current-page thought link lookup failed:", page_links)
        return {}
    end

    local result, seen = {}, {}
    for _, page_link in ipairs(page_links) do
        local href = self:_linkHref(page_link)
        if isThoughtHref(href) and not seen[href] then
            seen[href] = true
            local from_xpointer
            if page_link.a_xpointer then
                local coherent = true
                if reader_link and type(reader_link.isXpointerCoherent) == "function" then
                    local coherent_ok, value = pcall(function()
                        return reader_link:isXpointerCoherent(page_link.a_xpointer)
                    end)
                    coherent = coherent_ok and value == true
                end
                if coherent then
                    from_xpointer = page_link.a_xpointer
                end
            end

            local link_y = page_link.end_y
            if type(page_link.segments) == "table" and #page_link.segments > 0 then
                link_y = page_link.segments[#page_link.segments].y1
            end
            result[#result + 1] = {
                href = href,
                link = {
                    xpointer = page_link.section or page_link.uri or href,
                    marker_xpointer = page_link.section,
                    from_xpointer = from_xpointer,
                    a_xpointer = page_link.a_xpointer,
                    link_y = link_y,
                },
            }
        end
    end
    return result
end

-- Matched local books (unified annotations): no HTML anchors exist, underlines
-- are xpointer overlays. A thought is "on this page" when a visible overlay
-- record carries (or resolves to) review items in the unified store.
function M:_currentPageUnifiedThoughtLinks()
    local overlay = self._xpointer_overlay
    if not overlay then
        return {}
    end
    -- Prefer a fresh current-page computation; fall back to the last painted set.
    local ok, visible = pcall(function()
        return overlay:_computeVisible()
    end)
    if not ok or type(visible) ~= "table" then
        visible = overlay.visible or {}
    end
    local context = self._annotation_context
    local result = {}
    for _, entry in ipairs(visible) do
        local record = entry and entry.record
        if type(record) == "table" then
            local chapter_uid = record.chapter_uid
            local range = record.range
            if chapter_uid and range then
                local items = record.items
                if not items and context then
                    items = context.store:get(context.book_id, "thought",
                        chapter_uid .. ":" .. range)
                end
                if type(items) == "table" and #items > 0 then
                    local first = items[1] or {}
                    local preview = first.abstract or first.content or ""
                    result[#result + 1] = {
                        unified = true,
                        record = record,
                        items = items,
                        text = record.text or "",
                        preview = type(preview) == "string" and preview or "",
                    }
                end
            end
        end
    end
    return result
end

-- Shared entry for the "Thoughts on this page" menu list. Supports both native
-- cache books (anchor → native pages) and matched local books (overlay record →
-- resolved review items from the unified store).
function M:showCurrentPageThoughts()
    if not self._current_weread_book_id or not self.ui or not self.ui.document then
        self:showTransientInfo(_("This action requires an open WeRead book."), 1)
        return false
    end
    if self.settings:get("cache", {}).show_annotations == false then
        self:showTransientInfo(_("Underlines and thoughts are hidden."), 1)
        return true
    end

    local links = self:_currentPageThoughtLinks()
    if #links == 0 then
        self:showTransientInfo(_("No thoughts on this page."), 1)
        return true
    end

    local menu
    local items = {}
    for index, entry in ipairs(links) do
        local selected_entry = entry
        local label, callback
        if entry.unified then
            -- Matched local book: open the resolved review items directly.
            local preview = previewText(entry.preview or entry.text or "", 48)
            label = preview ~= "" and preview or T(_("Thought %1"), index)
            callback = function()
                if menu then UIManager:close(menu) end
                require("weread.ui.thought_popup").show(
                    ThoughtPopupConfig.build(self, entry.items))
            end
        else
            -- Native cache book: resolve the anchor to native pages first.
            local pages = self:_buildThoughtPagesFromHref(entry.href)
            local first = type(pages) == "table" and pages[1] or nil
            local preview = first and previewText(first.abstract, 48) or ""
            if preview == "" and first then
                preview = previewText(first.content, 48)
            end
            label = preview ~= "" and preview or T(_("Thought %1"), index)
            callback = function()
                if menu then UIManager:close(menu) end
                self:_openThoughtLink(selected_entry.link, time.now())
            end
        end
        items[#items + 1] = { text = label, callback = callback }
    end
    menu = self:showList(_("Thoughts on this page"), items,
        _("No thoughts on this page."))
    return true
end

function M:onShowCurrentPageWeReadThoughts()
    return self:showCurrentPageThoughts()
end

-- Shared open path for a thought anchor: resolve its native pages from the
-- SQLite thought DB (or trigger a repair download for legacy links), then
-- queue the popup. Used by the current-page list, taps, and the keyboard
-- "go to selected link" interception.
function M:_openThoughtLink(link, started)
    started = started or time.now()
    local href = self:_linkHref(link)
    if not isThoughtHref(href) then
        return false
    end

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
    thought_perf("thought_resolve", started, "cached=", tostring(was_cached),
        "pages=", tostring(type(pages) == "table" and #pages or 0))
    if pages == false then
        return true
    end
    if type(pages) ~= "table" or #pages == 0 then
        info = info or self:_parseThoughtHref(href)
        if info then
            return self:_downloadMissingThought()
        end
        return true
    end
    return self:_queueThoughtPopup(pages, link, started)
end

return M
