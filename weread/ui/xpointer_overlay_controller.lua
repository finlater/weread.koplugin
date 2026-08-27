-- EPUB-safe external annotations for arbitrary local reflowable books.
local UIManager = require("ui/uimanager")

local Content = require("weread.lib.content")
local Crypto = require("weread.lib.crypto")
local External = require("weread.lib.external_annotations")
local logger = require("weread.lib.logger")
local StandbyGuard = require("weread.lib.standby_guard")
local Overlay = require("weread.ui.xpointer_overlay")
local PluginUtil = require("weread.lib.plugin_util")
local ThoughtPopupConfig = require("weread.ui.thought_popup.popup_config")

local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}
-- Version 6 stores incomplete chapters and their review batches separately,
-- allowing cancellation and resume between individual network requests.
local SYNC_FORMAT_VERSION = 6
local VIEW_MODULE = "weread_xpointer_overlay"
local TOUCH_ZONE = "weread_xpointer_overlay_tap"
local PERF_TAG = "external_annotation_perf"

local function perf(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    logger.info(PERF_TAG .. " " .. table.concat(parts, ""))
end

local function elapsed_ms(started)
    return (os.clock() - started) * 1000
end

local function current_file(plugin)
    return plugin.ui and plugin.ui.document and plugin.ui.document.file
end

local function current_records(plugin)
    local file = current_file(plugin)
    if not file then return {} end
    local value = plugin.external_annotations_db:getDocument(file)
    return value and type(value.records) == "table" and value.records or {}
end

local function current_reading_fraction(plugin)
    local document = plugin.ui and plugin.ui.document
    if not document then return nil end
    local footer = plugin.ui.view and plugin.ui.view.footer
    local fraction = footer and tonumber(footer.percent_finished)
    if fraction then
        if fraction > 1 then fraction = fraction / 100 end
        return math.max(0, math.min(1, fraction))
    end
    local page, total
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
end

local function chapter_index_for_fraction(catalog, fraction)
    if not fraction or #catalog == 0 then return 1 end
    local total_words = 0
    for _, chapter in ipairs(catalog) do
        total_words = total_words + math.max(0,
            tonumber(chapter.wordCount or chapter.word_count or chapter.words) or 0)
    end
    if total_words > 0 then
        local target = fraction * total_words
        local consumed = 0
        for index, chapter in ipairs(catalog) do
            consumed = consumed + math.max(0,
                tonumber(chapter.wordCount or chapter.word_count or chapter.words) or 0)
            if target <= consumed then return index end
        end
    end
    return math.max(1, math.min(#catalog, math.ceil(fraction * #catalog)))
end

-- WeRead web-novel chapter titles carry per-update metadata suffixes such as
-- （第一更求推荐票）,(第二更),（求订阅）that the local EPUB TOC omits.  Only
-- groups containing an update keyword are stripped, so legitimate
-- parenthetical parts like （上） are preserved.
local UPDATE_SUFFIX_KEYWORDS = { "更", "求", "订", "阅", "票", "藏", "赏" }

local function has_update_keyword(text)
    for _i, keyword in ipairs(UPDATE_SUFFIX_KEYWORDS) do
        if text:find(keyword, 1, true) then return true end
    end
    return false
end

-- Strips a trailing （…）or (…) group that contains an update keyword.  Uses a
-- byte scan instead of Lua patterns, whose character classes operate on bytes
-- and would truncate multi-byte UTF-8 characters.  Paren positions point at
-- the first byte of each paren.
local function strip_update_suffix(title)
    for _ = 1, 3 do
        local close
        for i = #title, 1, -1 do
            local b = title:byte(i)
            if b == 0x29 then -- )
                close = i
                break
            end
            if b == 0x89 and i >= 3 -- ） (EF BC 89)
                and title:byte(i - 1) == 0xBC and title:byte(i - 2) == 0xEF then
                close = i - 2
                break
            end
        end
        if not close then return title end
        local open, open_len
        for i = close, 1, -1 do
            local b = title:byte(i)
            if b == 0x28 then -- (
                open, open_len = i, 1
                break
            end
            if b == 0x88 and i >= 3 -- （ (EF BC 88)
                and title:byte(i - 1) == 0xBC and title:byte(i - 2) == 0xEF then
                open, open_len = i - 2, 3
                break
            end
        end
        if not open then return title end
        local inner = title:sub(open + open_len, close - 1)
        if not has_update_keyword(inner) then return title end
        title = title:sub(1, open - 1)
    end
    return title
end

local function normalized_chapter_title(value)
    local title = tostring(value or "")
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    -- Normalize full-width punctuation and spaces to ASCII up front so the
    -- patterns below never place multi-byte characters inside a class.
    title = title:gsub("\xE3\x80\x80", " ") -- full-width space U+3000
    title = title:gsub("\xEF\xBC\x9A", ":") -- full-width colon ：
    title = title:gsub("\xE3\x80\x81", ",") -- ideographic comma 、
    for _, marker in ipairs({ "章", "节", "回" }) do
        local stripped, count = title:gsub(
            "^第.-" .. marker .. "[%s:%.%-]*", "", 1)
        if count > 0 then
            title = stripped
            break
        end
    end
    title = title:gsub(
        "^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%divxlcdmIVXLCDM%d]+[%s:%.%-]*", "")
    title = strip_update_suffix(title)
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    return title:gsub("%s+", " ")
end

local function local_catalog_matches(document, catalog, book_id)
    if not document or type(document.getToc) ~= "function" then return {} end
    local started = os.clock()
    local toc_started = os.clock()
    local ok, toc = pcall(document.getToc, document)
    local toc_ms = elapsed_ms(toc_started)
    if not ok or type(toc) ~= "table" then
        perf("book_id=", tostring(book_id or ""), "stage=catalog_match",
            "toc_ms=", string.format("%.1f", toc_ms),
            "match_ms=0.0", "matched=0", "error=true")
        return {}
    end
    local matched = {}
    local matched_count = 0
    -- Normalize every local TOC title once, then index them by normalized
    -- name (ordered occurrence lists) so the whole catalog matches in one
    -- linear pass instead of repeatedly re-normalizing TOC titles.
    local by_title = {}
    for index, entry in ipairs(toc) do
        if type(entry) == "table" then
            local norm = normalized_chapter_title(entry.title)
            if norm ~= "" then
                local list = by_title[norm]
                if not list then
                    list = {}
                    by_title[norm] = list
                end
                list[#list + 1] = index
            end
        end
    end
    local toc_index = 1
    for chapter_index, chapter in ipairs(catalog) do
        local target = normalized_chapter_title(chapter.title)
        if target ~= "" then
            local list = by_title[target]
            if list then
                for _, index in ipairs(list) do
                    if index >= toc_index then
                        local local_title = type(toc[index]) == "table"
                            and toc[index].title
                        matched[chapter_index] = {
                            title = tostring(local_title),
                            start_xpointer = toc[index].xpointer,
                            end_xpointer = type(toc[index + 1]) == "table"
                                and toc[index + 1].xpointer or nil,
                        }
                        matched_count = matched_count + 1
                        toc_index = index + 1
                        break
                    end
                end
            end
        end
    end
    perf("book_id=", tostring(book_id or ""), "stage=catalog_match",
        "toc_entries=", tostring(#toc),
        "toc_ms=", string.format("%.1f", toc_ms),
        "match_ms=", string.format("%.1f", elapsed_ms(started) - toc_ms),
        "matched=", tostring(matched_count))
    return matched
end

local function local_ranges(catalog, matches)
    local ranges = {}
    for index, chapter in ipairs(catalog) do
        local uid = chapter.chapterUid or chapter.chapterId
        local match = matches[index]
        if uid ~= nil and match and match.start_xpointer then
            ranges[tostring(uid)] = {
                start_xpointer = match.start_xpointer,
                end_xpointer = match.end_xpointer,
                title = match.title,
            }
        end
    end
    return ranges
end

local function is_supported(plugin)
    local document = plugin.ui and plugin.ui.document
    return document and document.info and not document.info.has_pages
        and type(document.getXPointer) == "function"
        and type(document.getScreenBoxesFromPositions) == "function"
end

local function is_page_turn_edge(plugin, pos)
    if not pos then return false end
    local cache = plugin.settings:get("cache", {})
    if cache.ignore_edge_thought_taps == false then return false end
    local ratio = tonumber(cache.edge_tap_ratio) or 0.20
    ratio = math.max(0.05, math.min(0.45, ratio))
    local width = require("device").screen:getWidth()
    return pos.x < width * ratio or pos.x > width * (1 - ratio)
end

function M:_xpointerOverlayPrototypeAvailable()
    return is_supported(self)
end

function M:_setupXPointerOverlayPrototype()
    if self._xpointer_overlay or not is_supported(self)
        or not self.ui.view or type(self.ui.view.registerViewModule) ~= "function" then
        return false
    end
    local cache = self.settings:get("cache", {})
    local overlay = Overlay:new{
        records = current_records(self),
        enabled = cache.show_annotations ~= false,
    }
    self.ui.view:registerViewModule(VIEW_MODULE, overlay)
    self._xpointer_overlay = overlay

    local Device = require("device")
    if Device:isTouchDevice() then
        self.ui:registerTouchZones({
            {
                id = TOUCH_ZONE,
                ges = "tap",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1,
                },
                overrides = {
                    "readerhighlight_tap",
                    "tap_top_left_corner", "tap_top_right_corner",
                    "tap_left_bottom_corner", "tap_right_bottom_corner",
                    "readerfooter_tap", "readermenu_ext_tap", "readermenu_tap",
                    "tap_forward", "tap_backward",
                },
                handler = function(ges)
                    return self:_onXPointerOverlayTap(ges)
                end,
            },
        })
        self._xpointer_overlay_touch_registered = true
    end
    return true
end

function M:_teardownXPointerOverlayPrototype()
    if self._xpointer_overlay_touch_registered and self.ui then
        self.ui:unRegisterTouchZones({
            {
                id = TOUCH_ZONE,
                overrides = {
                    "readerhighlight_tap",
                    "tap_top_left_corner", "tap_top_right_corner",
                    "tap_left_bottom_corner", "tap_right_bottom_corner",
                    "readerfooter_tap", "readermenu_ext_tap", "readermenu_tap",
                    "tap_forward", "tap_backward",
                },
            },
        })
    end
    self._xpointer_overlay_touch_registered = nil
    if self.ui and self.ui.view and self.ui.view.view_modules then
        self.ui.view.view_modules[VIEW_MODULE] = nil
    end
    self._xpointer_overlay = nil
end

function M:_onXPointerOverlayTap(ges)
    local overlay = self._xpointer_overlay
    if not overlay or not overlay.enabled or not ges or not ges.pos then
        return false
    end
    if is_page_turn_edge(self, ges.pos) then return false end
    local record = overlay:hitTest(ges.pos)
    if not record then return false end
    local source_items = record.items
    local items = {}
    if type(source_items) == "table" then
        for index, item in ipairs(source_items) do
            local copy = {}
            for key, value in pairs(type(item) == "table" and item or {}) do
                copy[key] = value
            end
            items[index] = copy
        end
    end
    if #items == 0 then
        items = {
            {
                abstract = record.text,
                author = _("WeRead"),
                content = _("No thoughts were returned for this underline."),
                likes_count = 0,
            },
        }
    elseif type(record.text) == "string" and record.text ~= "" then
        -- The review abstract can include nearby context and does not always
        -- equal the exact sentence represented by the tapped local underline.
        items[1].abstract = record.text
    end
    require("weread.ui.thought_popup").show(ThoughtPopupConfig.build(self, items))
    return true
end

local function current_entry(plugin)
    return plugin.external_annotations_db:getDocument(current_file(plugin))
end

function M:bindExternalAnnotationsBook(touchmenu_instance)
    if not self:requireLogin(true, true) then return end
    local path = current_file(self)
    if not path then return end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Match local book with WeRead"),
        input = (path:match("([^/]+)%.[^%.]+$") or ""),
        input_type = "text",
        buttons = { { {
            text = _("Cancel"), id = "close",
            callback = function() UIManager:close(dialog) end,
        }, {
            text = _("Search"), is_enter_default = true,
            callback = function()
                local keyword = dialog:getInputText()
                UIManager:close(dialog)
                self:runOnlineTask(_("Search"), function()
                    local result = self.client:gateway("/store/search", { keyword = keyword, count = 20 })
                    local items = {}
                    for _index, book in ipairs(External.normalize_search(result)) do
                        items[#items + 1] = {
                            text = book.title ~= "" and book.title or book.book_id,
                            post_text = book.author,
                            callback = function()
                                local old = current_entry(self) or {}
                                old.binding = {
                                    book_id = book.book_id, title = book.title,
                                    author = book.author, format = book.format,
                                    bound_at = os.time(),
                                }
                                old.records = {}
                                local saved, save_err = self.external_annotations_db:saveDocument(path, old)
                                if not saved then error(save_err) end
                                local cleared, clear_err =
                                    self.external_annotations_db:clearSyncCheckpoint(path)
                                if not cleared then error(clear_err) end
                                if self._xpointer_overlay then self._xpointer_overlay:setRecords({}) end
                                if touchmenu_instance
                                    and type(touchmenu_instance.updateItems) == "function" then
                                    touchmenu_instance:updateItems()
                                end
                                local ConfirmBox = require("ui/widget/confirmbox")
                                UIManager:show(ConfirmBox:new{
                                    title = _("Local book matched"),
                                    text = T(_("Matched with “%1”.\n\nSync underlines and thoughts now?\n\nYou can cancel at any time. Downloaded progress is saved and resumed automatically next time."),
                                        book.title ~= "" and book.title or book.book_id),
                                    ok_text = _("Sync underlines and thoughts"),
                                    cancel_text = _("Later"),
                                    ok_callback = function()
                                        self:syncExternalAnnotations()
                                    end,
                                })
                            end,
                        }
                    end
                    self:showList(_("Select matching WeRead book"), items, _("No search results."))
                end)
            end,
        } } },
    }
    self:showInputDialog(dialog)
end

function M:syncExternalAnnotations()
    self:startExternalAnnotationSync{}
end

-- Full-book or single-chapter annotation sync. opts.only_uid limits the
-- download to one catalog chapter (already-completed chapters stay in the
-- checkpoint and are re-located locally without network requests); passing
-- opts.source_catalog skips the chapterInfos fetch, so the single-chapter
-- picker does not trigger a second request when the sync starts.
function M:startExternalAnnotationSync(opts)
    opts = opts or {}
    local path = current_file(self)
    local entry = current_entry(self)
    local binding = entry and entry.binding
    if not binding then
        self:showInfo(_("Match this local book with a WeRead book first."))
        return
    end
    if not self:requireLogin(true, true) then return end
    if self._external_annotation_sync then
        self:showTransientInfo(
            _("Underlines and thoughts sync is already in progress."), 2)
        return
    end

    local DownloadDialog = require("weread.ui.download_dialog")
    local request = {
        path = path,
        entry = entry,
        binding = binding,
        cancelled = false,
        only_uid = opts.only_uid,
        source_catalog = opts.source_catalog,
        local_ranges = opts.local_ranges,
        chapter_titles = opts.chapter_titles,
        chapter_local_titles = opts.chapter_local_titles,
    }
    local cancel_request
    local progress
    progress = DownloadDialog:new{
        title = _("Preparing local-book annotation sync…"),
        description = _(
            "You can cancel at any time. Downloaded progress is saved and resumed automatically next time."),
        progress_max = 1,
        buttons = { {
            {
                text = _("Cancel"),
                callback = function()
                    if self._external_annotation_sync ~= request then return end
                    cancel_request()
                end,
            },
        } },
    }
    request.progress = progress
    self._external_annotation_sync = request
    progress:show()
    request.standby_guard = StandbyGuard.acquire()
    local label = _("Sync local-book underlines and thoughts")
    logger.info("external annotation sync started:",
        "book_id=", tostring(binding.book_id), "path=", tostring(path))

    local function request_is_current()
        return self._external_annotation_sync == request
            and not request.cancelled
            and current_file(self) == request.path
    end

    local function finish_request()
        if self._external_annotation_sync == request then
            self._external_annotation_sync = nil
        end
        if request.progress then
            request.progress:close()
            request.progress = nil
        end
        if request.standby_guard then
            StandbyGuard.release(request.standby_guard)
            request.standby_guard = nil
        end
    end

    cancel_request = function()
        if request.cancelled then return end
        request.cancelled = true
        finish_request()
        self:showTransientInfo(_(
            "Sync cancelled. Downloaded progress was saved and will resume next time."), 3)
    end

    local function fail_request(err)
        if not request_is_current() then
            finish_request()
            return
        end
        finish_request()
        logger.warn("external annotation sync interrupted:", tostring(err))
        self:showInfo(T(_(
            "Underlines and thoughts sync was interrupted:\n%1\n\nDownloaded progress was saved. Retry to continue."),
            tostring(err or "unknown")))
    end

    local function schedule_step(callback, delay)
        UIManager:scheduleIn(delay or 0.1, function()
            if not request_is_current() then
                if self._external_annotation_sync == request then finish_request() end
                return
            end
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then fail_request(err) end
        end)
    end

    local download_next_chapter
    local download_current_review_batch
    local finish_current_chapter
    local finish_sync

    finish_sync = function()
        request.progress:setTitle(_("Matching underlines in the local book…"))
        -- For a single-chapter sync, locating the whole accumulated checkpoint
        -- on every pick makes matching slower and slower as the checkpoint
        -- grows.  Chapters whose records were already saved are kept as-is;
        -- only the picked chapter and any completed chapter that never
        -- produced records (e.g. an earlier interrupted run) are re-located.
        local saved_uids = {}
        for _i, record in ipairs(type(request.entry.records) == "table"
            and request.entry.records or {}) do
            saved_uids[tostring(record.chapter_uid or "")] = true
        end
        local chapters = {}
        for _, chapter in ipairs(request.catalog) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId)
            local downloaded = request.completed[uid]
            if downloaded and #(downloaded.underlines or {}) > 0 then
                if not request.only_uid or uid == request.only_uid
                    or not saved_uids[uid] then
                    chapters[#chapters + 1] = downloaded
                end
            end
        end
        local locate_started = os.clock()
        local records, stats = External.locate(self.ui.document, chapters, {
            chapter_ranges = request.local_ranges,
            chapter_titles = request.chapter_titles,
            chapter_local_titles = request.chapter_local_titles,
        })
        local locate_ms = elapsed_ms(locate_started)
        if stats.total > 0 and stats.located == 0 then
            error(T(_(
                "Downloaded %1 underlines, but none could be matched. Existing data was not changed; retry to continue."),
                tostring(stats.total)))
        end
        -- Keep projected records outside this run, including records created
        -- before the current chapter checkpoint existed.
        local synced_uids = {}
        for _i, chapter in ipairs(chapters) do
            synced_uids[chapter.chapter_uid] = true
        end
        local merged = {}
        for _i, record in ipairs(type(request.entry.records) == "table"
            and request.entry.records or {}) do
            if not synced_uids[tostring(record.chapter_uid or "")] then
                merged[#merged + 1] = record
            end
        end
        for _i, record in ipairs(records) do
            merged[#merged + 1] = record
        end
        request.entry.records = merged
        request.entry.stats = stats
        request.entry.synced_at = os.time()
        local save_started = os.clock()
        local saved, save_err = self.external_annotations_db:saveDocument(
            request.path, request.entry)
        local save_ms = elapsed_ms(save_started)
        if not saved then error(save_err) end
        if not request.only_uid then
            local cleared, clear_err = self.external_annotations_db:clearSyncCheckpoint(
                request.path)
            if not cleared then error(clear_err) end
        end
        local overlay_started = os.clock()
        if self._xpointer_overlay then self._xpointer_overlay:setRecords(merged) end
        UIManager:setDirty(self.dialog, "ui")
        local overlay_ms = elapsed_ms(overlay_started)
        finish_request()
        perf("book_id=", tostring(binding.book_id), "stage=sync_finish",
            "chapters=", tostring(#chapters),
            "located=", tostring(stats.located), "total=", tostring(stats.total),
            "locate_ms=", string.format("%.1f", locate_ms),
            "save_ms=", string.format("%.1f", save_ms),
            "overlay_ms=", string.format("%.1f", overlay_ms))
        logger.info("external annotation sync completed:",
            "located=", tostring(stats.located), "total=", tostring(stats.total))
        self:showInfo(T(_("Sync completed: %1/%2 underlines matched."),
            tostring(stats.located), tostring(stats.total)))
    end

    finish_current_chapter = function()
        local value = {
            book_id = binding.book_id,
            chapter_uid = request.current_uid,
            underlines = request.current_underlines.underlines or {},
            reviews = request.current_reviews,
            complete = true,
        }
        local saved, save_err = self.external_annotations_db:finishSyncChapter(
            request.path, request.current_index, request.current_uid, value)
        if not saved then error(save_err) end
        request.completed[request.current_uid] = value
        request.partials[request.current_uid] = nil
        request.completed_count = request.completed_count + 1
        request.progress:reportProgress(request.completed_count)
        schedule_step(download_next_chapter)
    end

    download_current_review_batch = function()
        local batch_index = request.review_batch_index
        if batch_index > #request.review_batches then
            finish_current_chapter()
            return
        end
        local ok, result, err = self.client:get_chapter_reviews_batch(
            binding.book_id, request.current_api_uid,
            request.review_batches[batch_index])
        if not ok or type(result) ~= "table"
            or type(result.reviews) ~= "table" then
            error(err or "could not download thoughts")
        end
        local saved, save_err = self.external_annotations_db:saveSyncReviewBatch(
            request.path, request.current_uid, batch_index, result.reviews)
        if not saved then error(save_err) end
        for _, review in ipairs(result.reviews) do
            request.current_reviews[#request.current_reviews + 1] = review
        end
        request.review_batch_index = batch_index + 1
        request.progress:reportProgress(request.completed_count
            + batch_index / #request.review_batches)
        schedule_step(download_current_review_batch)
    end

    local function resume_current_chapter(partial)
        request.current_underlines = {
            underlines = type(partial.underlines) == "table"
                and partial.underlines or {},
        }
        request.ranges = require("weread.lib.thoughts").collect_ranges(
            request.current_underlines)
        request.review_batches = self.client:build_chapter_review_batches(
            request.ranges)
        request.current_reviews = {}
        request.review_batch_index = 1
        for _, saved_batch in ipairs(partial.review_batches or {}) do
            local saved_index = tonumber(saved_batch.batch_index)
            if saved_index ~= request.review_batch_index
                or saved_index > #request.review_batches then
                break
            end
            for _, review in ipairs(saved_batch.reviews or {}) do
                request.current_reviews[#request.current_reviews + 1] = review
            end
            request.review_batch_index = saved_index + 1
        end
        if #request.review_batches > 0 then
            request.progress:reportProgress(request.completed_count
                + (request.review_batch_index - 1) / #request.review_batches)
            schedule_step(download_current_review_batch)
        else
            schedule_step(finish_current_chapter)
        end
    end

    download_next_chapter = function()
        local selected_index, selected_chapter, selected_uid, selected_api_uid
        local function consider(chapter_index, chapter)
            local api_uid = chapter.chapterUid or chapter.chapterId
            local uid = tostring(api_uid)
            if not request.completed[uid] then
                selected_index, selected_chapter, selected_uid, selected_api_uid =
                    chapter_index, chapter, uid, api_uid
                return true
            end
            return false
        end
        if request.only_uid then
            for chapter_index, chapter in ipairs(request.catalog) do
                if tostring(chapter.chapterUid or chapter.chapterId) == request.only_uid then
                    consider(chapter_index, chapter)
                    break
                end
            end
        else
            for chapter_index, chapter in ipairs(request.catalog) do
                if consider(chapter_index, chapter) then break end
            end
        end
        if not selected_chapter then
            finish_sync()
            return
        end
        request.current_index = selected_index
        request.current_chapter = selected_chapter
        request.current_uid = selected_uid
        request.current_api_uid = selected_api_uid
        request.progress:setTitle(T(_(
            "Downloading underlines and thoughts · chapter %1/%2"),
            tostring(selected_index), tostring(#request.catalog)))
        local partial = request.partials[selected_uid]
        if partial then
            resume_current_chapter(partial)
            return
        end
        local ok, underlines, err = self.client:get_chapter_underlines(
            binding.book_id, selected_api_uid)
        if not ok or type(underlines) ~= "table" then
            error(err or "could not download underlines")
        end
        request.current_underlines = underlines
        request.ranges = require("weread.lib.thoughts").collect_ranges(underlines)
        request.review_batches = self.client:build_chapter_review_batches(
            request.ranges)
        request.review_batch_index = 1
        request.current_reviews = {}
        local partial_value = {
            book_id = binding.book_id,
            chapter_uid = selected_uid,
            underlines = underlines.underlines or {},
            reviews = {},
            complete = false,
        }
        local saved, save_err = self.external_annotations_db:saveSyncChapter(
            request.path, selected_index, selected_uid, partial_value)
        if not saved then error(save_err) end
        request.partials[selected_uid] = partial_value
        if #request.review_batches > 0 then
            schedule_step(download_current_review_batch)
        else
            schedule_step(finish_current_chapter)
        end
    end

    local function prepare_sync()
        request.progress:setTitle(_("Loading WeRead chapter list…"))
        local book = { bookId = binding.book_id, book_id = binding.book_id,
            title = binding.title, author = binding.author }
        local source_catalog = request.source_catalog
        if not source_catalog then
            Content.ensure_reader_state(self.client, book)
            source_catalog = Content.fetch_catalog(self.client, book)
        end
        request.catalog = {}
        local signature_parts = { tostring(binding.book_id) }
        for _, chapter in ipairs(type(source_catalog) == "table" and source_catalog or {}) do
            local uid = chapter.chapterUid or chapter.chapterId
            if uid ~= nil then
                request.catalog[#request.catalog + 1] = chapter
                signature_parts[#signature_parts + 1] = tostring(uid)
            end
        end
        if #request.catalog == 0 then error("empty chapter catalog") end
        if not request.local_ranges then
            request.local_ranges = local_ranges(request.catalog,
                local_catalog_matches(self.ui.document, request.catalog, binding.book_id))
        end
        if not request.chapter_titles then
            request.chapter_titles = {}
            for _index, chapter in ipairs(request.catalog) do
                local uid = tostring(chapter.chapterUid or chapter.chapterId)
                request.chapter_titles[uid] = tostring(chapter.title or "")
            end
        end
        if not request.chapter_local_titles then
            request.chapter_local_titles = {}
            for uid, range in pairs(request.local_ranges or {}) do
                if range.title then request.chapter_local_titles[uid] = range.title end
            end
        end
        local signature = Crypto.sha256_hex(table.concat(signature_parts, ":"))
        local checkpoint = self.external_annotations_db:getSyncCheckpoint(path)
        if not checkpoint
            or tostring(checkpoint.book_id or "") ~= tostring(binding.book_id)
            or checkpoint.catalog_signature ~= signature
            or tonumber(checkpoint.format_version) ~= SYNC_FORMAT_VERSION then
            checkpoint = {
                book_id = tostring(binding.book_id),
                format_version = SYNC_FORMAT_VERSION,
                catalog_signature = signature,
                total = #request.catalog,
                started_at = os.time(),
                chapters = {},
            }
            local saved, save_err = self.external_annotations_db:replaceSyncCheckpoint(
                path, checkpoint)
            if not saved then error(save_err) end
        end
        request.completed = {}
        request.partials = {}
        request.completed_count = 0
        local catalog_uids = {}
        for _, chapter in ipairs(request.catalog) do
            catalog_uids[tostring(chapter.chapterUid or chapter.chapterId)] = true
        end
        for _, chapter in ipairs(checkpoint.chapters or {}) do
            local uid = tostring(chapter.chapter_uid or "")
            if uid ~= "" and catalog_uids[uid] then
                if chapter.complete == true then
                    request.completed[uid] = chapter
                    request.completed_count = request.completed_count + 1
                else
                    request.partials[uid] = chapter
                end
            end
        end
        request.progress.progress_max = #request.catalog
        request.progress:reportProgress(request.completed_count)
        if request.completed_count > 0 then
            request.progress:setTitle(T(_(
                "Resuming underlines and thoughts · %1/%2 chapters completed"),
                tostring(request.completed_count), tostring(#request.catalog)))
        end
        schedule_step(download_next_chapter)
    end

    local started = self:runOnlineTask(label, function()
        schedule_step(prepare_sync)
    end)
    if not started then finish_request() end
end

-- On-demand single-chapter sync: lets the user pick one WeRead chapter whose
-- underlines and thoughts are downloaded instead of the whole book at once,
-- which keeps per-session request counts low enough to stay under WeRead's
-- rate limits. Chapters already checkpointed as complete are marked and are
-- never re-downloaded.
function M:syncExternalAnnotationsChapter()
    local path = current_file(self)
    local entry = current_entry(self)
    local binding = entry and entry.binding
    if not binding then
        self:showInfo(_("Match this local book with a WeRead book first."))
        return
    end
    if not self:requireLogin(true, true) then return end
    if self._external_annotation_sync then
        self:showTransientInfo(
            _("Underlines and thoughts sync is already in progress."), 2)
        return
    end
    self:runOnlineTask(_("Loading WeRead chapter list…"), function()
        local book = { bookId = binding.book_id, book_id = binding.book_id,
            title = binding.title, author = binding.author }
        Content.ensure_reader_state(self.client, book)
        local catalog = Content.fetch_catalog(self.client, book)
        if #catalog == 0 then
            self:showInfo(_("No chapters to sync."))
            return
        end
        -- Mark chapters already checkpointed as complete so the user can
        -- drive the sync chapter by chapter over time without re-downloading.
        local completed = {}
        local signature_parts = { tostring(binding.book_id) }
        for _index, chapter in ipairs(catalog) do
            local uid = chapter.chapterUid or chapter.chapterId
            if uid ~= nil then
                signature_parts[#signature_parts + 1] = tostring(uid)
            end
        end
        local checkpoint = self.external_annotations_db:getSyncCheckpoint(path)
        if checkpoint
            and tostring(checkpoint.book_id or "") == tostring(binding.book_id)
            and checkpoint.catalog_signature
                == Crypto.sha256_hex(table.concat(signature_parts, ":"))
            and tonumber(checkpoint.format_version) == SYNC_FORMAT_VERSION then
            for _index, chapter in ipairs(checkpoint.chapters or {}) do
                if chapter.complete == true then
                    completed[tostring(chapter.chapter_uid or "")] = true
                end
            end
        end
        local items = {}
        local match_started = os.clock()
        local local_matches = local_catalog_matches(self.ui.document, catalog, binding.book_id)
        local chapter_ranges = local_ranges(catalog, local_matches)
        local matched_count = 0
        for _uid in pairs(chapter_ranges) do matched_count = matched_count + 1 end
        local chapter_titles = {}
        local chapter_local_titles = {}
        for index, chapter in ipairs(catalog) do
            local api_uid = chapter.chapterUid or chapter.chapterId
            local uid = tostring(api_uid)
            chapter_titles[uid] = tostring(chapter.title or "")
            local match = local_matches[index]
            if match and match.title then chapter_local_titles[uid] = match.title end
            items[#items + 1] = {
                text = match and match.title or chapter.title or uid,
                post_text = completed[uid] and _("Synced") or nil,
                callback = function()
                    self:startExternalAnnotationSync{
                        source_catalog = catalog,
                        only_uid = uid,
                        local_ranges = chapter_ranges,
                        chapter_titles = chapter_titles,
                        chapter_local_titles = chapter_local_titles,
                    }
                end,
            }
        end
        perf("book_id=", tostring(binding.book_id), "stage=chapter_picker",
            "catalog=", tostring(#catalog),
            "matched=", tostring(matched_count),
            "match_ms=", string.format("%.1f", elapsed_ms(match_started)))
        items.current = chapter_index_for_fraction(
            catalog, current_reading_fraction(self))
        self:showList(_("Select chapter to sync"), items, _("No chapters to sync."))
    end)
end

function M:clearExternalAnnotations(touchmenu_instance)
    local cleared, clear_err = self.external_annotations_db:clearDocument(current_file(self))
    if not cleared then
        self:showInfo(T(_("Could not clear local-book annotation data: %1"),
            tostring(clear_err)))
        return
    end
    if self._xpointer_overlay then self._xpointer_overlay:setRecords({}) end
    UIManager:setDirty(self.dialog, "ui")
    if touchmenu_instance and type(touchmenu_instance.updateItems) == "function" then
        touchmenu_instance:updateItems()
    end
    self:showTransientInfo(_("Local-book annotation data cleared."), 2)
end

function M:getXPointerOverlayPrototypeMenuItems()
    return {
        {
            text_func = function()
                local entry = current_entry(self)
                return entry and entry.binding
                    and T(_("Matched book: %1"), entry.binding.title) or _("Match with WeRead book")
            end,
            callback = function(touchmenu_instance)
                self:bindExternalAnnotationsBook(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                local entry = current_entry(self)
                local located = entry and entry.stats
                    and tonumber(entry.stats.located)
                if located then
                    return T(_("Sync underlines and thoughts · %1 matched"),
                        tostring(located))
                end
                return _("Sync underlines and thoughts")
            end,
            enabled_func = function()
                local entry = current_entry(self)
                return entry and entry.binding ~= nil
            end,
            callback = function() self:syncExternalAnnotations() end,
        },
        {
            text = _("Sync single chapter…"),
            enabled_func = function()
                local entry = current_entry(self)
                return entry and entry.binding ~= nil
            end,
            callback = function() self:syncExternalAnnotationsChapter() end,
        },
        {
            text = _("Clear data"),
            enabled_func = function() return current_entry(self) ~= nil end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:clearExternalAnnotations(touchmenu_instance)
            end,
        },
    }
end

function M:_invalidateXPointerOverlayLayout()
    if self._xpointer_overlay then self._xpointer_overlay:invalidate() end
end

-- CREngine emits UpdatePos after every layout-affecting typography change
-- (font size/family, line spacing, word spacing, margins, etc.).  The current
-- page number may stay unchanged, so the page-keyed rectangle cache must be
-- discarded before ReaderView paints the newly reflowed document.
function M:onUpdatePos()
    self:_invalidateXPointerOverlayLayout()
end

function M:onDocumentRerendered()
    self:_invalidateXPointerOverlayLayout()
end

return M
