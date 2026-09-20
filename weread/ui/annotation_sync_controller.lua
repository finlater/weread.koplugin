-- UI adapter for the shared-book annotation pipeline.
local UIManager = require("ui/uimanager")
local Content = require("weread.lib.content")
local Chapters = require("weread.lib.annotation_chapters")
local PluginUtil = require("weread.lib.plugin_util")
local logger = require("weread.lib.logger")
local _ = PluginUtil.tr
local T = PluginUtil.T
local M = {}

local function compare_xpointers(document, a, b)
    local ok, order = pcall(document.compareXPointers, document, a, b)
    if ok then return order end
end

local function file(plugin)
    return plugin.ui and plugin.ui.document and plugin.ui.document.file
end

local function annotation_progress(state)
    local completed = tonumber(state.completed) or 0
    local current = tonumber(state.current) or 0
    local count = tonumber(state.count) or 0
    local fraction = count > 0 and math.max(0, math.min(1, current / count)) or 0
    if state.stage == "thoughts" then
        return completed + fraction * 0.5
    elseif state.stage == "source" then
        return completed + 0.5
    elseif state.stage == "match" then
        return completed + 0.5 + fraction * 0.5
    end
    return completed
end

function M:_annotationStore()
    if not self.annotation_store then
        self.annotation_store = require("weread.lib.annotation_store"):new(self.settings)
    end
    return self.annotation_store
end

function M:_annotationBinding()
    local path = file(self)
    if not path then return nil end
    local entry = self.external_annotations_db:getDocument(path)
    if entry and entry.binding then return entry.binding end
    local book_id = self:detectWeReadBook()
    if not book_id then return nil end
    local books = self.settings:get("books", {})
    local book = books[tostring(book_id)] or books[book_id]
    if not book then return nil end
    return { book_id = tostring(book_id), title = book.title, author = book.author,
        format = book.format, automatic = true }
end

function M:_usesUnifiedAnnotations()
    if self._unified_annotations_active ~= nil then return self._unified_annotations_active end
    local binding = self:_annotationBinding()
    if not binding then return false end
    if binding.automatic then
        local books = self.settings:get("books", {})
        local book = books[binding.book_id] or books[tonumber(binding.book_id)]
        local descriptor = Chapters.descriptor(book, file(self))
        if descriptor and descriptor.clean then return true end
    end
    local store = self:_annotationStore()
    local key = store.documentKey(file(self))
    return store:get(binding.book_id, "display", key) == true
        or store:get(binding.book_id, "manual_only", key) == true
end

function M:_prepareAnnotationContext(online, refresh_catalog)
    local path = file(self)
    if not path or not self:_xpointerOverlayPrototypeAvailable() then return nil end
    local perf = PluginUtil.reader_open_perf
    local started = perf("context_begin", nil, "session=", self._reader_session_gen)
    local binding = self:_annotationBinding()
    started = perf("annotation_binding", started, "book_id=", binding and binding.book_id or "none")
    if not binding then return nil end
    local context = self._annotation_context
    if not refresh_catalog and context and context.path == path and context.book_id == tostring(binding.book_id)
        and (context.catalog and #context.catalog > 0 or not online) then
        perf("context_cached", started)
        return context
    end
    local store = self:_annotationStore()
    local books = self.settings:get("books", {})
    local book_id = tostring(binding.book_id)
    local book = books[book_id] or books[tonumber(book_id)]
    local descriptor = binding.automatic and Chapters.descriptor(book, path)
    local catalog = store:get(book_id, "meta", "catalog") or book and book.chapters
    if online and (not catalog or refresh_catalog) then
        local remote = { bookId = book_id, book_id = book_id, title = binding.title,
            author = binding.author, format = binding.format }
        Content.ensure_reader_state(self.client, remote)
        catalog = Content.fetch_catalog(self.client, remote)
        assert(type(catalog) == "table" and #catalog > 0, _("No chapter catalog available."))
        store:put(book_id, "meta", "catalog", catalog)
        if refresh_catalog then store:put(book_id, "meta", "prune_catalog", catalog) end
    end
    catalog = catalog or descriptor and descriptor.chapters or {}
    local document_key = store.documentKey(path)
    local overrides = store:get(book_id, "chapter_mapping", document_key)
    started = perf("annotation_catalog", started, "chapters=", #catalog)
    local selected, ranges = Chapters.map(self.ui.document, catalog, descriptor, overrides)
    started = perf("chapter_mapping", started, "chapters=", #selected)
    local prune_catalog = store:get(book_id, "meta", "prune_catalog")
    if prune_catalog then
        local valid, retained = {}, {}
        for _, chapter in ipairs(prune_catalog) do valid[Chapters.uid(chapter)] = true end
        for _, chapter in ipairs(selected) do
            if valid[Chapters.uid(chapter)] then retained[#retained + 1] = chapter end
        end
        selected = retained
    end
    if not descriptor or overrides then
        -- Legacy combined EPUBs and arbitrary local editions may contain only
        -- part of the remote catalog. Never fetch chapters absent from this file.
        local mapped = {}
        for _, chapter in ipairs(selected) do
            if ranges[Chapters.uid(chapter)] then mapped[#mapped + 1] = chapter end
        end
        selected = mapped
    end
    started = perf("document_identity", started)
    store:importLegacy(book_id, path, document_key)
    started = perf("legacy_import", started)
    context = { path = path, book_id = book_id, binding = binding, book = book,
        store = store, document_key = document_key, chapters = selected, ranges = ranges,
        descriptor = descriptor, catalog = catalog, overrides = overrides,
        statuses = store:reconcileRanges(book_id, document_key, ranges) }
    perf("saved_annotation_status", started)
    self._annotation_context = context
    return context
end

function M:_annotationSummary(context)
    local stats = { total = 0, located = 0, unmatched = 0, chapters = 0 }
    for _, chapter in ipairs(context.chapters) do
        local key = context.store:projectionKey(context.document_key, Chapters.uid(chapter))
        local status = context.statuses[key]
        if status then
            stats.chapters = stats.chapters + 1
            for _, field in ipairs({ "total", "located" }) do
                stats[field] = stats[field] + (tonumber(status.stats[field]) or 0)
            end
        end
    end
    stats.unmatched = stats.total - stats.located
    return stats
end

-- Visibility is meaningful only after this document has usable annotation
-- results. The global preference alone must not make a new clean download look
-- as if annotations are already displayed. Legacy EPUBs with baked-in markup
-- continue to use the global preference until their unified migration finishes.
function M:_annotationsVisibleForCurrentDocument()
    if self.settings:get("cache", {}).show_annotations == false then return false end
    if not self:_usesUnifiedAnnotations() then
        return self:detectWeReadBook() ~= nil
    end
    local context = self._annotation_context
    if not context then
        local ok, prepared = pcall(self._prepareAnnotationContext, self, false)
        if ok then context = prepared end
    end
    return context ~= nil and self:_annotationSummary(context).chapters > 0
end

function M:_annotationChapterIndex(context, point)
    local document = self.ui and self.ui.document
    if not document or not point or type(document.compareXPointers) ~= "function" then
        return nil
    end

    -- Keep only chapter boundaries, never chapter text or annotation rows.
    -- Chapters.map returns document order, so index construction is linear.
    local lookup = context._chapter_lookup
    if not lookup or lookup.chapters ~= context.chapters or lookup.ranges ~= context.ranges then
        lookup = { chapters = context.chapters, ranges = context.ranges, starts = {} }
        local previous
        for index, chapter in ipairs(context.chapters or {}) do
            local range = context.ranges and context.ranges[Chapters.uid(chapter)]
            local start = range and range.start_xpointer
            if start then
                local order = previous and compare_xpointers(document, previous, start) or 1
                -- Equal TOC anchors retain the first chapter, as before.
                if order == 1 then
                    lookup.starts[#lookup.starts + 1] = { point = start, index = index }
                    previous = start
                end
            end
        end
        context._chapter_lookup = lookup
    end
    local starts, cursor = lookup.starts, lookup.cursor
    -- Ordinary same-chapter page turns need at most two comparisons.
    if cursor then
        local lower = compare_xpointers(document, point, starts[cursor].point)
        if lower == nil then return nil end
        if lower ~= 1 then
            local upper = starts[cursor + 1] and compare_xpointers(document, point, starts[cursor + 1].point)
            if not starts[cursor + 1] or upper == 1 then return starts[cursor].index end
        end
    end
    local low, high = 1, #starts
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local order = compare_xpointers(document, point, starts[middle].point)
        if order == nil then return nil end
        if order == 1 then high = middle - 1
        else low = middle + 1 end
    end
    lookup.cursor = high > 0 and high or nil
    return high > 0 and starts[high].index or nil
end

function M:_currentAnnotationChapter(context)
    if not context or #context.chapters == 0 then return nil end
    local document = self.ui and self.ui.document
    if document and type(document.getXPointer) == "function" then
        local ok, point = pcall(document.getXPointer, document)
        local index = ok and self:_annotationChapterIndex(context, point)
        local chapter = index and context.chapters[index]
        if chapter then
            local range = context.ranges[Chapters.uid(chapter)]
            if not range or not range.end_xpointer then return chapter end
            if compare_xpointers(document, point, range.end_xpointer) == 1 then
                return chapter
            end
            -- The located chapter has an explicit boundary that does not
            -- accept this position (an unmapped appendix, or an unusable
            -- comparison): never claim it through the single-chapter
            -- fallback below.
            return nil
        end
    end
    -- The fallback for a single mapped chapter covers positions the document
    -- cannot judge (missing anchor or missing boundary information).
    if #context.chapters == 1 then return context.chapters[1] end
end

function M:_refreshAnnotationOverlay()
    local context, overlay = self._annotation_context, self._xpointer_overlay
    if not context or not overlay or overlay.enabled == false then return end
    if #context.chapters == 0 then
        overlay._annotation_window = nil
        overlay:setRecords({})
        return
    end
    if context.binding.automatic and not (context.descriptor and context.descriptor.clean)
        and not self._unified_annotations_active then
        local generation = context.generation or 0
        if context._overlay_blocked_generation == generation then return end
        if self:_annotationSummary(context).chapters < #context.chapters then
            context._overlay_blocked_generation = generation
            overlay:setRecords({})
            return
        end
    end
    local document = self.ui.document
    -- A page turn normally emits both PageUpdate and PosUpdate. In paged mode
    -- both callbacks see the same stable page, so the latter must not repeat
    -- chapter boundary comparisons before the overlay paint cache can be used.
    local view = overlay.view or self.ui.view
    local page = document.getCurrentPage and document:getCurrentPage()
    local generation = context.generation or 0
    if view and view.view_mode == "page" and page ~= nil then
        if overlay._annotation_refresh_context == context
            and overlay._annotation_refresh_generation == generation
            and overlay._annotation_refresh_page == page then
            return
        end
        overlay._annotation_refresh_context = context
        overlay._annotation_refresh_generation = generation
        overlay._annotation_refresh_page = page
    end
    local current = document:getXPointer()
    local function chapter_at(point)
        return self:_annotationChapterIndex(context, point) or 1
    end
    local active = chapter_at(current)
    local last = active
    if document.getPageXPointer and document.getCurrentPage then
        local count = document.getVisiblePageCount and document:getVisiblePageCount() or 1
        local next_page = document:getCurrentPage() + count
        local stop
        local at_end = document.getPageCount and next_page > document:getPageCount()
        if not at_end then
            stop = document:getPageXPointer(next_page)
        end
        -- A missing page anchor must not load the rest of a large book.
        last = stop and chapter_at(stop) or (at_end and #context.chapters or active)
    end
    local window = tostring(active) .. ":" .. tostring(last) .. ":" .. tostring(generation)
    if overlay._annotation_window == window then return end
    local records = {}
    for index = math.max(1, active - 1), math.min(#context.chapters, last + 1) do
        local uid = Chapters.uid(context.chapters[index])
        local key = context.store:projectionKey(context.document_key, uid)
        local projection = context.store:get(context.book_id, "projection", key)
        for _, record in ipairs(projection and projection.records or {}) do
            records[#records + 1] = record
        end
    end
    -- locate() emits projections in document order.  Tell the overlay so it
    -- can use its ordered interval index instead of rescanning every record on
    -- each page turn. Legacy records keep the conservative linear fallback.
    overlay:setRecords(records, true)
    overlay._annotation_window = window
end

function M:_cancelUnifiedAnnotationSync(preserve_pending)
    local request = self._external_annotation_sync
    if not request then return end
    request.cancelled = true
    if request.job then request.job.cancelled = true end
    local dismiss = request.progress and request.progress.dismiss_callback
    if request.progress then
        request.progress.dismiss_callback = nil
        request.progress:close()
    end
    if request.guard then require("weread.lib.standby_guard").release(request.guard) end
    request.guard = nil
    if not preserve_pending then self._annotation_pending_prefetch = nil end
    if request.worker_handle and self.prefetch_worker then
        self.prefetch_worker:cancel(request.worker_handle, "cancelled")
        return
    end
    self._external_annotation_sync = nil
    -- Clear ownership before resuming Trapper: cancellation must not deliver
    -- a late response, schedule a retry or close a newer job's dialog.
    if dismiss then dismiss() end
end

function M:_finishAnnotationPrefetchWorker(request, result)
    if request.guard then
        require("weread.lib.standby_guard").release(request.guard)
        request.guard = nil
    end
    request.worker_handle = nil
    if self._external_annotation_sync ~= request then return end
    if not request.cancelled and type(result) == "table" and result.ok then
        if result.value and result.value.auth then
            local WorkerSettings = require("weread.lib.worker_settings")
            if not WorkerSettings.merge(self.settings, request.auth_fingerprint,
                result.value.auth) then
                logger.info("skip annotation worker auth write-back: parent auth changed")
            end
        end
    elseif not request.cancelled then
        logger.warn("annotation prefetch worker failed:",
            tostring(type(result) == "table" and result.error or "no result"))
    end
    self._external_annotation_sync = nil
    local pending = self._annotation_pending_prefetch
    self._annotation_pending_prefetch = nil
    if pending then self:_runAnnotationJob(pending.context, pending.options) end
end

function M:_runAnnotationPrefetchWorker(request, context, options)
    local worker = self.prefetch_worker
    if not worker or not worker:available() then
        self._external_annotation_sync = nil
        logger.warn("annotation prefetch skipped: subprocess worker unavailable")
        return false
    end
    local WorkerSettings = require("weread.lib.worker_settings")
    local AnnotationWorker = require("weread.lib.annotation_prefetch_worker")
    request.auth_fingerprint = WorkerSettings.fingerprint(self.settings)
    local ok, handle = worker:start {
        queue = true,
        timeout = 180,
        task = function(worker_context)
            return AnnotationWorker.run(self.settings, self.client, context,
                options.chapters or context.chapters, worker_context)
        end,
        on_launch = function(pid, available_kb)
            if self._external_annotation_sync ~= request then return end
            request.guard = require("weread.lib.standby_guard").acquire()
            logger.info("annotation prefetch worker started:",
                "pid=", tostring(pid),
                "available_kb=", tostring(available_kb or "unknown"))
        end,
        on_progress = function(state)
            logger.info("annotation prefetch progress:",
                "stage=", tostring(state.stage),
                "chapter=", tostring(state.index or 0) .. "/"
                    .. tostring(state.total or 0),
                "items=", tostring(state.current or 0) .. "/"
                    .. tostring(state.count or 0))
        end,
        on_done = function(result)
            self:_finishAnnotationPrefetchWorker(request, result)
        end,
    }
    if ok and self._external_annotation_sync == request then
        request.worker_handle = handle
    end
    return ok
end

-- Same pipe/termination path as chapter downloads. Never run the whole
-- annotation job in a child: matching uses the open document, and completed
-- thought batches must be committed by the parent before starting the next one.
function M:_runAnnotationNetwork(request, task)
    local ok_json, Json = pcall(require, "json")
    if not ok_json then Json = require("rapidjson") end
    local WorkerSettings = require("weread.lib.worker_settings")
    local fingerprint = WorkerSettings.fingerprint(self.settings)
    local completed, encoded = request.trapper:dismissableRunInSubprocess(function()
        local auth_result = WorkerSettings.capture(self.settings)
        local ok, values = xpcall(function()
            local first, second, third = task()
            -- Named slots preserve nil holes without turning them into JSON null.
            return { first = first, second = second, third = third }
        end, debug.traceback)
        -- LuaJSON represents null as a function, which Trapper's binary table
        -- serializer rejects. Send JSON over its existing plain-string pipe.
        return Json.encode({ ok = ok, values = values, auth = auth_result() })
    end, request.progress, true)
    request.progress.dismiss_callback = nil
    if self._external_annotation_sync ~= request or request.cancelled then return end
    if not completed then error("could not start annotation worker") end
    if not encoded or encoded == "" then error("annotation worker returned no result") end
    local result = Json.decode(encoded)
    if result.auth then WorkerSettings.merge(self.settings, fingerprint, result.auth) end
    if not result.ok then error(result.values, 0) end
    return { result.values.first, result.values.second, result.values.third }
end

function M:_runAnnotationJob(context, options)
    options = options or {}
    if options.background or options.prefetch then
        if not self:canPrefetchAnnotations() then return false end
        -- Every automatic path must use the headless worker. Hiding a progress
        -- dialog does not make network, parsing or SQLite work non-blocking.
        options.background, options.prefetch = true, true
    end
    if self._external_annotation_sync then
        if options.background then
            self._annotation_pending_prefetch = { context = context, options = options }
            return
        end
        if self._external_annotation_sync.worker_handle then
            self._annotation_pending_prefetch = { context = context, options = options }
            self:_cancelUnifiedAnnotationSync(true)
            return
        end
        self:_cancelUnifiedAnnotationSync()
    end
    local Sync = require("weread.lib.annotation_sync")
    local request = { context = context, session = self._reader_session_gen, prefetch = options.prefetch }
    self._external_annotation_sync = request
    if options.prefetch then
        return self:_runAnnotationPrefetchWorker(request, context, options)
    end
    local function perf(stage, started, ...)
        return PluginUtil.reader_open_perf(stage, started,
            "book_id=", context.book_id, "session=", request.session, ...)
    end
    local queued = perf("annotation_job_queued", nil,
        "background=", options.background == true, "chapters=", #(options.chapters or context.chapters))
    local job_started
    if not options.background then
        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        if ok_ffi and type(ffiutil.runInSubProcess) == "function" then
            local ok_trapper, trapper = pcall(require, "ui/trapper")
            if ok_trapper then request.trapper = trapper end
        end
        local job_chapters = options.chapters or context.chapters
        request.progress = require("weread.ui.download_dialog"):new{
            title = _("Sync underlines and thoughts"),
            description = _("Pause at any time. Saved chapters and batches will be reused."),
            progress_max = #job_chapters,
            buttons = { { { text = _("Pause"), callback = function()
                self:_cancelUnifiedAnnotationSync()
                self:showTransientInfo(_("Annotation progress saved."), 2)
            end } } },
        }
        request.progress:show()
        request.guard = require("weread.lib.standby_guard").acquire()
    end
    local source_book = context.book or { bookId = context.book_id, book_id = context.book_id,
        title = context.binding.title, format = context.binding.format }
    request.job = Sync:new{
        perf = perf,
        store = context.store, client = self.client, book_id = context.book_id,
        chapters = options.chapters or context.chapters, ranges = context.ranges,
        document = not options.prefetch and self.ui.document or nil,
        document_key = not options.prefetch and context.document_key or nil,
        refresh = options.refresh or options.clear_existing, clear_existing = options.clear_existing,
        offline = options.offline, async_network = request.trapper ~= nil,
        is_online = function() return self:isNetworkConnected() end,
        on_reset = function()
            for _, chapter in ipairs(options.chapters or context.chapters) do
                context.statuses[context.store:projectionKey(context.document_key, Chapters.uid(chapter))] = nil
            end
            context.generation = (context.generation or 0) + 1
            self:_refreshAnnotationOverlay()
            UIManager:setDirty(self.dialog, "ui")
        end,
        fetch_source = function(chapter)
            local html, format = request.job:callNetwork(function()
                local body = Content.fetch_chapter_xhtml(self.client, self.settings, source_book, chapter)
                if source_book._content_format == "txt" then
                    body = context.store:get(context.book_id, "original", Chapters.uid(chapter)) or {}
                end
                return body, source_book._content_format
            end)
            source_book._content_format = format
            return html
        end,
        on_chapter = function(uid, projection)
            if projection then
                local key = context.store:projectionKey(context.document_key, uid)
                context.statuses[key] = { stats = projection.stats, revision = projection.revision,
                    matcher_version = projection.matcher_version, range_key = projection.range_key }
                context.generation = (context.generation or 0) + 1
                -- Activate each committed chapter before the next request can
                -- fail or be paused, including books with old embedded markup.
                local activate = not self._unified_annotations_active
                    and (tonumber(projection.stats.located) or 0) > 0
                if activate then
                    context.store:put(context.book_id, "display", context.document_key, true)
                    self._unified_annotations_active = true
                    if self._xpointer_overlay then self._xpointer_overlay._annotation_window = nil end
                end
                self:_refreshAnnotationOverlay()
                if activate then self:applyAnnotationVisibility() end
                UIManager:setDirty(self.dialog, "ui")
            end
        end,
    }
    local step, safe_step
    step = function()
        if self._external_annotation_sync ~= request then return end
        if not options.prefetch and (file(self) ~= context.path
            or self._reader_session_gen ~= request.session) then
            self:_cancelUnifiedAnnotationSync()
            return
        end
        if not job_started then job_started = perf("annotation_job_start", queued) end
        local done, state = request.job:step()
        while done == false and state and state.network do
            -- Trapper yields from this outer coroutine, never from Sync.thread.
            -- Resuming the pipeline before the child returns would lose data.
            local values = self:_runAnnotationNetwork(request, state.network)
            if self._external_annotation_sync ~= request then return end
            if file(self) ~= context.path or self._reader_session_gen ~= request.session then
                self:_cancelUnifiedAnnotationSync()
                return
            end
            done, state = request.job:step(unpack(values, 1, 3))
        end
        if done == nil or done then
            perf("annotation_job_total", job_started, "ok=", done == true)
            local pending = self._annotation_pending_prefetch
            self:_cancelUnifiedAnnotationSync()
            if done == nil then
                logger.warn("annotation_sync interrupted:", state)
                if not options.background then
                    if state == Sync.NETWORK_REQUIRED then
                        self:showInfo(_("Connect to the network to download annotation data. Saved matching progress will be reused."))
                    else
                        self:showInfo(T(_("Annotation sync paused: %1\nSaved progress will be reused."), state))
                    end
                end
            end
            if not options.prefetch then
                local prune_catalog = done and context.store:get(context.book_id, "meta", "prune_catalog")
                if prune_catalog then
                    context.store:pruneCatalog(context.book_id, prune_catalog)
                    context.store:put(context.book_id, "meta", "prune_catalog", nil)
                end
                if done and not options.background then
                    local summary = self:_annotationSummary(context)
                    self:showInfo(T(_("Matched %1/%2 underlines in %3/%4 chapters."),
                        tostring(summary.located), tostring(summary.total),
                        tostring(summary.chapters), tostring(#context.chapters)))
                end
            end
            if done and pending then self:_runAnnotationJob(pending.context, pending.options) end
            return
        end
        if request.progress then
            local title
            if state.stage == "thoughts" then
                title = T(_("Downloading thoughts %1/%2 · chapter %3/%4"),
                    tostring(state.current or 0), tostring(state.count or 0),
                    tostring(state.index), tostring(state.total))
            elseif state.stage == "match" then
                title = T(_("Matching underlines %1/%2 · chapter %3/%4"),
                    tostring(state.current or 0), tostring(state.count or 0),
                    tostring(state.index), tostring(state.total))
            elseif state.stage == "source" then
                title = T(_("Downloading underline source text · chapter %1/%2"),
                    tostring(state.index), tostring(state.total))
            elseif state.stage == "underlines" then
                title = T(_("Downloading underlines · chapter %1/%2"),
                    tostring(state.index), tostring(state.total))
            else
                title = T(_("%1 · chapter %2/%3"), _("Downloading"),
                    tostring(state.index), tostring(state.total))
            end
            -- Update the bar before setTitle repaints the dialog, so the text
            -- and bar always describe the same point in the current chapter.
            request.progress:reportProgress(annotation_progress(state))
            request.progress:setTitle(title)
        end
        UIManager:scheduleIn(math.max(0.1, state.delay or 0.1), safe_step)
    end
    safe_step = function()
        local function run()
            local ok, err = xpcall(step, debug.traceback)
            if not ok and self._external_annotation_sync == request then
                self:_cancelUnifiedAnnotationSync()
                logger.warn("annotation_sync UI:", err)
                if not options.background then
                    self:showInfo(T(_("Annotation sync paused: %1\nSaved progress will be reused."), tostring(err)))
                end
            end
        end
        if request.trapper then request.trapper:wrap(run) else run() end
    end
    UIManager:scheduleIn(0.1, safe_step)
end

function M:startUnifiedAnnotationSync(options)
    options = options or {}
    if not self:_annotationBinding() then self:bindExternalAnnotationsBook(); return end
    if not self:_xpointerOverlayPrototypeAvailable() then
        self:showInfo(_("Annotation matching requires a reflowable document.")); return
    end
    local function start()
        local context = self:_prepareAnnotationContext(not options.offline, options.refresh)
        if not context or #context.chapters == 0 then
            self:showInfo(_("No matching chapters found. Check the bound book and local chapter titles."))
            return
        end
        local chapters = options.chapters
        if options.all_chapters == true then
            chapters = context.chapters
        end
        if not chapters then
            local current = self:_currentAnnotationChapter(context)
            if not current then
                self:showInfo(_("Current position is outside the matched chapters. Use “Choose chapters to match”."))
                return
            end
            chapters = { current }
        end
        if #chapters == 0 then
            self:showInfo(_("No matching chapters found. Check the bound book and local chapter titles."))
            return
        end
        context.store:put(context.book_id, "meta", "enabled", true)
        context.store:put(context.book_id, "manual_only", context.document_key, nil)
        local cache = self.settings:get("cache")
        cache.show_annotations = true
        self.settings:set("cache", cache)
        self.settings:flush()
        if self._xpointer_overlay then self._xpointer_overlay:setEnabled(true) end
        local job_options = {}
        for key, value in pairs(options) do job_options[key] = value end
        job_options.chapters = chapters
        self:_runAnnotationJob(context, job_options)
    end
    if options.offline then return start() end
    if not self:requireLogin(true, true) then return end
    return self:runOnlineTask(_("Sync underlines and thoughts"), start)
end

function M:ensureAnnotationDisplay()
    if not self:_xpointerOverlayPrototypeAvailable() then
        self:showInfo(_("Annotation matching requires a reflowable document."))
        return true
    end
    local binding = self:_annotationBinding()
    if not binding then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{ text = _("Bind this book to WeRead to match underlines and thoughts?"),
            ok_text = _("Match with WeRead book"), ok_callback = function() self:bindExternalAnnotationsBook() end })
        return true
    end
    local context = self:_prepareAnnotationContext(false)
    local summary = context and self:_annotationSummary(context)
    if summary and summary.chapters > 0 then return false end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Match underlines and thoughts for “%1”?\nOnly the current chapter is processed. Choose chapters to match more."), binding.title or binding.book_id),
        ok_text = _("Start matching"), cancel_text = _("Later"),
        ok_callback = function()
            local cache = self.settings:get("cache")
            cache.show_annotations = true
            self.settings:set("cache", cache)
            self.settings:flush()
            self:startUnifiedAnnotationSync({ offline = not self:isNetworkConnected() })
        end,
    })
    return true
end

function M:onUnifiedAnnotationsReady()
    local perf = PluginUtil.reader_open_perf
    local started = perf("annotations_begin", nil, "session=", self._reader_session_gen)
    self._unified_annotations_active = nil
    self._annotation_context = nil
    local ok, context = pcall(self._prepareAnnotationContext, self, false)
    started = perf("context_total", started, "ok=", ok, "available=", ok and context ~= nil)
    if not ok then logger.warn("annotation context:", context); return end
    if not context then return end
    -- Recover partial chapter selections created by older builds that wrote a
    -- projection but waited for the whole document before marking it usable.
    if self:_annotationSummary(context).located > 0 then
        context.store:put(context.book_id, "display", context.document_key, true)
    end
    self._unified_annotations_active = self:_usesUnifiedAnnotations()
    started = perf("annotation_display_state", started)
    self:_refreshAnnotationOverlay()
    perf("saved_annotation_overlay", started)
    -- Opening a book only displays saved projections. Downloading or matching
    -- is always initiated from an explicit menu action.
end

function M:prefetchChapterAnnotations(book, chapter)
    if not self:canPrefetchAnnotations() then return end
    local book_id = tostring(book.book_id or book.bookId)
    local store = self:_annotationStore()
    if not store:get(book_id, "meta", "enabled") then return end
    local uid = Chapters.uid(chapter)
    if store:get(book_id, "source_status", uid)
        and not store:get(book_id, "refresh", uid) then return end
    self:_runAnnotationJob({ book_id = book_id, book = book, binding = book,
        store = store, chapters = { chapter } }, { background = true, prefetch = true })
end

function M:isAnnotationPrefetchEnabled()
    return self.settings:get("cache").prefetch_annotations == true
end

function M:canPrefetchAnnotations()
    return self.settings:get("cache").auto_prefetch_next_chapter == true
        and self:isAnnotationPrefetchEnabled() and self:isNetworkConnected()
end

function M:cancelAnnotationPrefetch()
    local pending = self._annotation_pending_prefetch
    if pending and pending.options.prefetch then self._annotation_pending_prefetch = nil end
    local request = self._external_annotation_sync
    if request and request.prefetch then
        -- A user-requested match may be waiting for the child to exit.
        self:_cancelUnifiedAnnotationSync(true)
    end
end

function M:setAnnotationPrefetchEnabled(enabled)
    local cache = self.settings:get("cache")
    cache.prefetch_annotations = enabled == true
    self.settings:set("cache", cache)
    self.settings:flush()
    if not enabled then self:cancelAnnotationPrefetch() end
    return true
end

function M:_annotationSelectionModel(context)
    local document, toc, current = self.ui.document
    local ok, entries = pcall(document.getToc, document)
    if ok and type(entries) == "table" then toc = entries end
    local ok_point, point = pcall(document.getXPointer, document)
    if ok_point then current = self:_annotationChapterIndex(context, point) end
    local sources = context.store:list(context.book_id, "source_status")
    local refreshing = context.store:list(context.book_id, "refresh")
    local matcher = require("weread.lib.external_annotations").MATCHER_VERSION
    return require("weread.lib.chapter_selection"):new(context.chapters, context.ranges, toc, current,
        function(chapter)
            local uid = Chapters.uid(chapter)
            local status = context.statuses[context.store:projectionKey(context.document_key, uid)]
            return not refreshing[uid] and sources[uid] and status
                and status.revision == sources[uid].revision and status.matcher_version == matcher
                and status.range_key == Chapters.rangeKey(context.ranges[uid]) or false
        end)
end

function M:_saveAnnotationChapterMatch(context, node, uid)
    local binding = self:_annotationBinding()
    if file(self) ~= context.path or not binding or tostring(binding.book_id) ~= context.book_id then return end
    if not node.xpointer then return end
    if uid then
        local range = context.ranges[uid]
        assert(not range or range.start_xpointer == node.xpointer, _("This WeRead chapter is already linked."))
    end
    local overrides = {}
    for point, value in pairs(context.overrides or {}) do overrides[point] = value end
    overrides[node.xpointer] = uid or false
    self:_cancelUnifiedAnnotationSync()
    local _, ranges = Chapters.map(self.ui.document, context.catalog, context.descriptor, overrides)
    local affected = {}
    for chapter_uid in pairs(context.ranges) do affected[chapter_uid] = true end
    for chapter_uid in pairs(ranges) do affected[chapter_uid] = true end
    local changes = { { kind = "chapter_mapping", key = context.document_key, value = overrides } }
    for chapter_uid in pairs(affected) do
        if Chapters.rangeKey(context.ranges[chapter_uid]) ~= Chapters.rangeKey(ranges[chapter_uid]) then
            -- Include partial/legacy projections with no completed status.
            -- A neighbouring chapter's end boundary may have changed too.
            local key = context.store:projectionKey(context.document_key, chapter_uid)
            for _, kind in ipairs({ "projection", "matching", "status" }) do
                changes[#changes + 1] = { kind = kind, key = key }
            end
        end
    end
    context.store:write(context.book_id, changes)
    self._annotation_context = nil
    local updated = self:_prepareAnnotationContext(false)
    if self._xpointer_overlay then
        self._xpointer_overlay:clearAnnotationState()
    end
    self:_refreshAnnotationOverlay()
    UIManager:setDirty(self.dialog, "ui")
    return updated
end

function M:_chooseAnnotationChapterMatch(context, node, on_saved)
    local session, menu = self._reader_session_gen
    local function save(uid)
        if session ~= self._reader_session_gen then return end
        local ok, updated = pcall(self._saveAnnotationChapterMatch, self, context, node, uid)
        if not ok then
            self:showInfo(T(_("Could not save chapter match: %1"), tostring(updated)))
        elseif updated then
            if menu then UIManager:close(menu) end
            on_saved(updated)
        end
    end
    local items = {}
    for _index, chapter in ipairs(context.catalog) do
        local uid = Chapters.uid(chapter)
        local range = context.ranges[uid]
        local occupied = range and range.start_xpointer ~= node.xpointer
        local title = string.rep("  ", math.min(5, math.max(0, (tonumber(chapter.level) or 1) - 1)))
            .. (chapter.title or uid)
        local current = range ~= nil and not occupied
        items[#items + 1] = { text = title, select_enabled = not occupied, current = current,
            detail = range and T(_("Local: %1"), range.title or range.toc_index) or _("No local chapter linked"),
            status = current and "✓ " .. _("Current match") or occupied and _("Already linked") or _("Available"),
            callback = function() if not occupied then save(uid) end end }
    end
    menu = require("weread.ui.annotation_chapter_picker").show{
        choices = items, local_title = node.title,
        on_remove = node.chapter and function() save(false) end or nil,
    }
    return menu
end

function M:chooseAnnotationChapters()
    if not self:_annotationBinding() then return self:bindExternalAnnotationsBook() end
    local function show()
        local context = self:_prepareAnnotationContext(self:isNetworkConnected())
        if not context or not context.catalog or #context.catalog == 0 then
            self:showInfo(_("No chapter catalog available.")); return
        end
        local session = self._reader_session_gen
        return require("weread.ui.annotation_chapter_picker").show{
            model = self:_annotationSelectionModel(context), book_title = context.binding.title,
            on_edit = function(node, rebuild)
                self:_chooseAnnotationChapterMatch(context, node, function(updated)
                    context = updated
                    rebuild(self:_annotationSelectionModel(context))
                end)
            end,
            on_select = function(chapters)
                if session ~= self._reader_session_gen or file(self) ~= context.path then return end
                self:startUnifiedAnnotationSync({ chapters = chapters, clear_existing = true })
            end,
        }
    end
    local context = self:_prepareAnnotationContext(false)
    if context and context.catalog and #context.catalog > 0 then return show() end
    if not self:requireLogin(true, true) then return end
    self:runOnlineTask(_("Loading chapter list..."), show)
end

function M:getUnifiedAnnotationMenuItems()
    local binding = self:_annotationBinding()
    return {
        { text = binding and T(_("Linked WeRead book: %1"), binding.title or binding.book_id)
                or _("Match with WeRead book"),
            callback = function(menu) self:bindExternalAnnotationsBook(menu) end },
        { text_func = function()
                local context = self._annotation_context
                if not context then return _("Continue matching") end
                local summary = self:_annotationSummary(context)
                return T(_("Continue matching · %1/%2 chapters, %3 underlines"),
                    tostring(summary.chapters), tostring(#context.chapters), tostring(summary.located))
            end, text = _("Continue matching"), callback = function()
            self:startUnifiedAnnotationSync({
                all_chapters = true,
                offline = not self:isNetworkConnected(),
            })
        end },
        { text = _("Choose chapters to match"), callback = function()
            self:chooseAnnotationChapters()
        end },
        { text = _("Clear underlines and thoughts"), callback = function()
            self:clearUnifiedAnnotationProjections() end },
    }
end

function M:clearUnifiedAnnotationProjections()
    local context = self:_prepareAnnotationContext(false)
    if not context then return end
    self:_cancelUnifiedAnnotationSync()
    local ok, clear_err = pcall(function()
        -- The mapped chapter list may cover only the current local edition.
        -- Clear derived rows book-wide so unmapped/stale chapters and old
        -- document keys cannot reappear after reopening the book.
        context.store:clearKinds(context.book_id, {
            "source", "source_status", "download", "batch", "thought",
            "refresh", "projection", "matching", "status", "generation",
            "display", "manual_only",
        })
        context.store:write(context.book_id, {
            { kind = "manual_only", key = context.document_key, value = true },
        })

        -- A migrated local-book database can otherwise seed the unified store
        -- again. Preserve only its binding and discard records/checkpoints.
        local legacy = self.external_annotations_db
        if legacy and context.path then
            local entry = legacy:getDocument(context.path)
            local cleared, legacy_err = legacy:clearDocument(context.path)
            if not cleared then error(legacy_err or "legacy annotation cleanup failed") end
            if entry and entry.binding then
                local saved, save_err = legacy:saveDocument(context.path, {
                    binding = entry.binding,
                })
                if not saved then error(save_err or "annotation binding restore failed") end
            end
        end
    end)
    if not ok then
        logger.warn("annotation cleanup failed:", tostring(clear_err))
        self:showInfo(T(_("Failed to clear underlines and thoughts: %1"), tostring(clear_err)))
        return false
    end
    context.statuses = {}
    context.generation = (context.generation or 0) + 1
    self._unified_annotations_active = true
    if self._xpointer_overlay then
        self._xpointer_overlay._annotation_window = nil
        self._xpointer_overlay:setRecords({}, true)
    end
    self:applyAnnotationVisibility()
    self:showTransientInfo(_("Underlines and thoughts cleared. Match again to download fresh data."), 3)
    return true
end

return M
