-- EPUB-safe external annotations for arbitrary local reflowable books.
local UIManager = require("ui/uimanager")

local Content = require("weread.lib.content")
local Crypto = require("weread.lib.crypto")
local External = require("weread.lib.external_annotations")
local logger = require("weread.lib.logger")
local StandbyGuard = require("weread.lib.standby_guard")
local Overlay = require("weread.ui.xpointer_overlay")
local PluginUtil = require("weread.lib.plugin_util")

local _ = PluginUtil.tr
local T = PluginUtil.T

local M = {}
-- Version 6 stores incomplete chapters and their review batches separately,
-- allowing cancellation and resume between individual network requests.
local SYNC_FORMAT_VERSION = 6
local VIEW_MODULE = "weread_xpointer_overlay"
local TOUCH_ZONE = "weread_xpointer_overlay_tap"

local function current_file(plugin)
    return plugin.ui and plugin.ui.document and plugin.ui.document.file
end

local function current_records(plugin)
    local file = current_file(plugin)
    if not file then return {} end
    local value = plugin.external_annotations_db:getDocument(file)
    return value and type(value.records) == "table" and value.records or {}
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
    local items = record.items
    if type(items) ~= "table" or #items == 0 then
        items = {
            {
                abstract = record.text,
                author = _("WeRead"),
                content = _("No thoughts were returned for this underline."),
                likes_count = 0,
            },
        }
    end
    require("weread.ui.thought_popup").show{ pages = items }
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
        local chapters = {}
        for _, chapter in ipairs(request.catalog) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId)
            local downloaded = request.completed[uid]
            if downloaded and #(downloaded.underlines or {}) > 0 then
                chapters[#chapters + 1] = downloaded
            end
        end
        local records, stats = External.locate(self.ui.document, chapters)
        if stats.total > 0 and stats.located == 0 then
            error(T(_(
                "Downloaded %1 underlines, but none could be matched. Existing data was not changed; retry to continue."),
                tostring(stats.total)))
        end
        request.entry.records = records
        request.entry.stats = stats
        request.entry.synced_at = os.time()
        local saved, save_err = self.external_annotations_db:saveDocument(
            request.path, request.entry)
        if not saved then error(save_err) end
        local cleared, clear_err = self.external_annotations_db:clearSyncCheckpoint(
            request.path)
        if not cleared then error(clear_err) end
        if self._xpointer_overlay then self._xpointer_overlay:setRecords(records) end
        UIManager:setDirty(self.dialog, "ui")
        finish_request()
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
        for chapter_index, chapter in ipairs(request.catalog) do
            local api_uid = chapter.chapterUid or chapter.chapterId
            local uid = tostring(api_uid)
            if not request.completed[uid] then
                selected_index, selected_chapter, selected_uid, selected_api_uid =
                    chapter_index, chapter, uid, api_uid
                break
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
        Content.ensure_reader_state(self.client, book)
        local source_catalog = Content.fetch_catalog(self.client, book)
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
