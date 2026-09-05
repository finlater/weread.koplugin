-- UI adapter for the shared-book annotation pipeline.
local UIManager = require("ui/uimanager")
local Content = require("weread.lib.content")
local Chapters = require("weread.lib.annotation_chapters")
local PluginUtil = require("weread.lib.plugin_util")
local logger = require("weread.lib.logger")
local _ = PluginUtil.tr
local T = PluginUtil.T
local M = {}

local function file(plugin)
    return plugin.ui and plugin.ui.document and plugin.ui.document.file
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
end

function M:_prepareAnnotationContext(online, refresh_catalog)
    local path = file(self)
    if not path or not self:_xpointerOverlayPrototypeAvailable() then return nil end
    local binding = self:_annotationBinding()
    if not binding then return nil end
    local context = self._annotation_context
    if not refresh_catalog and context and context.path == path and context.book_id == tostring(binding.book_id)
        and (#context.chapters > 0 or not online) then return context end
    local store = self:_annotationStore()
    local books = self.settings:get("books", {})
    local book_id = tostring(binding.book_id)
    local book = books[book_id] or books[tonumber(book_id)]
    local descriptor = binding.automatic and Chapters.descriptor(book, path)
    local catalog = descriptor and descriptor.chapters
        or store:get(book_id, "meta", "catalog") or book and book.chapters
    if online and (not catalog or refresh_catalog) then
        local remote = { bookId = book_id, book_id = book_id, title = binding.title,
            author = binding.author, format = binding.format }
        Content.ensure_reader_state(self.client, remote)
        catalog = Content.fetch_catalog(self.client, remote)
        assert(type(catalog) == "table" and #catalog > 0, _("No chapter catalog available."))
        store:put(book_id, "meta", "catalog", catalog)
        if refresh_catalog then store:put(book_id, "meta", "prune_catalog", catalog) end
    end
    local selected, ranges = Chapters.map(self.ui.document, catalog or {}, descriptor)
    local prune_catalog = store:get(book_id, "meta", "prune_catalog")
    if prune_catalog then
        local valid, retained = {}, {}
        for _, chapter in ipairs(prune_catalog) do valid[Chapters.uid(chapter)] = true end
        for _, chapter in ipairs(selected) do
            if valid[Chapters.uid(chapter)] then retained[#retained + 1] = chapter end
        end
        selected = retained
    end
    if not descriptor then
        -- Legacy combined EPUBs and arbitrary local editions may contain only
        -- part of the remote catalog. Never fetch chapters absent from this file.
        local mapped = {}
        for _, chapter in ipairs(selected) do
            if ranges[Chapters.uid(chapter)] then mapped[#mapped + 1] = chapter end
        end
        selected = mapped
    end
    local document_key = store.documentKey(path)
    store:importLegacy(book_id, path, document_key)
    context = { path = path, book_id = book_id, binding = binding, book = book,
        store = store, document_key = document_key, chapters = selected, ranges = ranges,
        descriptor = descriptor, statuses = store:list(book_id, "status") }
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

    local latest_index, latest_start
    for index, chapter in ipairs(context.chapters or {}) do
        local range = context.ranges
            and context.ranges[Chapters.uid(chapter)]
        local start_xpointer = range and range.start_xpointer
        if start_xpointer then
            local ok_start, start_cmp = pcall(document.compareXPointers,
                document, start_xpointer, point)
            if ok_start and (start_cmp == 0 or start_cmp == 1) then
                if not latest_start then
                    latest_index, latest_start = index, start_xpointer
                else
                    local ok_order, order = pcall(document.compareXPointers,
                        document, latest_start, start_xpointer)
                    if ok_order and order == 1 then
                        latest_index, latest_start = index, start_xpointer
                    end
                end
            end
        end
    end
    return latest_index
end

function M:_refreshAnnotationOverlay()
    local context, overlay = self._annotation_context, self._xpointer_overlay
    if not context or not overlay or #context.chapters == 0 then return end
    if context.binding.automatic and not (context.descriptor and context.descriptor.clean)
        and not self._unified_annotations_active
        and self:_annotationSummary(context).chapters < #context.chapters then
        overlay:setRecords({})
        return
    end
    local document = self.ui.document
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
        if not document.getPageCount or next_page <= document:getPageCount() then
            stop = document:getPageXPointer(next_page)
        end
        last = stop and chapter_at(stop) or #context.chapters
    end
    local window = tostring(active) .. ":" .. tostring(last) .. ":" .. tostring(context.generation or 0)
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
    overlay:setRecords(records)
    overlay._annotation_window = window
end

function M:_cancelUnifiedAnnotationSync(preserve_pending)
    local request = self._external_annotation_sync
    if not request then return end
    if request.job then request.job.cancelled = true end
    if request.progress then request.progress:close() end
    if request.guard then require("weread.lib.standby_guard").release(request.guard) end
    request.guard = nil
    if request.worker_handle and self.prefetch_worker then
        request.cancelled = true
        self.prefetch_worker:cancel(request.worker_handle, "cancelled")
        if not preserve_pending then self._annotation_pending_prefetch = nil end
        return
    end
    self._external_annotation_sync = nil
    if not preserve_pending then self._annotation_pending_prefetch = nil end
end

function M:_finishAnnotationPrefetchWorker(request, result)
    if request.guard then
        require("weread.lib.standby_guard").release(request.guard)
        request.guard = nil
    end
    request.worker_handle = nil
    if type(result) == "table" and result.ok then
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
    if self._external_annotation_sync == request then
        self._external_annotation_sync = nil
    end
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

function M:_runAnnotationJob(context, options)
    options = options or {}
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
    if not options.background then
        request.progress = require("weread.ui.download_dialog"):new{
            title = _("Sync underlines and thoughts"),
            description = _("Pause at any time. Saved chapters and batches will be reused."),
            progress_max = #context.chapters,
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
        store = context.store, client = self.client, book_id = context.book_id,
        chapters = options.chapters or context.chapters, ranges = context.ranges,
        document = not options.prefetch and self.ui.document or nil,
        document_key = not options.prefetch and context.document_key or nil,
        refresh = options.refresh, offline = options.offline,
        fetch_source = function(chapter)
            local html = Content.fetch_chapter_xhtml(self.client, self.settings, source_book, chapter)
            if source_book._content_format == "txt" then
                return context.store:get(context.book_id, "original", Chapters.uid(chapter)) or {}
            end
            return html
        end,
        on_chapter = function(uid, projection)
            if projection then
                local key = context.store:projectionKey(context.document_key, uid)
                context.statuses[key] = { stats = projection.stats, revision = projection.revision }
                context.generation = (context.generation or 0) + 1
                self:_refreshAnnotationOverlay()
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
        local done, state = request.job:step()
        if done == nil or done then
            local pending = self._annotation_pending_prefetch
            self:_cancelUnifiedAnnotationSync()
            if done == nil then
                logger.warn("annotation_sync interrupted:", state)
                if not options.background then
                    self:showInfo(T(_("Annotation sync paused: %1\nSaved progress will be reused."), state))
                end
            elseif not options.prefetch then
                local prune_catalog = context.store:get(context.book_id, "meta", "prune_catalog")
                if prune_catalog then
                    context.store:pruneCatalog(context.book_id, prune_catalog)
                    context.store:put(context.book_id, "meta", "prune_catalog", nil)
                end
                local summary = self:_annotationSummary(context)
                if summary.chapters == #context.chapters and #context.chapters > 0 then
                    context.store:put(context.book_id, "display", context.document_key, true)
                    if not self._unified_annotations_active then
                        self._unified_annotations_active = true
                        if self._xpointer_overlay then self._xpointer_overlay._annotation_window = nil end
                        self:_refreshAnnotationOverlay()
                        self:applyAnnotationVisibility()
                    end
                end
                if not options.background then
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
            request.progress:setTitle(title)
            request.progress:reportProgress(state.completed)
        end
        UIManager:scheduleIn(state.delay or 0.01, safe_step)
    end
    safe_step = function()
        local ok, err = xpcall(step, debug.traceback)
        if not ok then
            self:_cancelUnifiedAnnotationSync()
            logger.warn("annotation_sync UI:", err)
            if not options.background then
                self:showInfo(T(_("Annotation sync paused: %1\nSaved progress will be reused."), tostring(err)))
            end
        end
    end
    UIManager:scheduleIn(0.01, safe_step)
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
        context.store:put(context.book_id, "meta", "enabled", true)
        context.store:put(context.book_id, "manual_only", context.document_key, nil)
        local cache = self.settings:get("cache")
        cache.show_annotations = true
        self.settings:set("cache", cache)
        self.settings:flush()
        if self._xpointer_overlay then self._xpointer_overlay:setEnabled(true) end
        self:_runAnnotationJob(context, options)
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
        text = T(_("Match underlines and thoughts for “%1”?\nOnly chapters in this file are processed. Future prefetched chapters can prepare annotations automatically."), binding.title or binding.book_id),
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
    self._unified_annotations_active = nil
    self._annotation_context = nil
    local ok, context = pcall(self._prepareAnnotationContext, self, false)
    if not ok then logger.warn("annotation context:", context); return end
    if not context then return end
    self._unified_annotations_active = self:_usesUnifiedAnnotations()
    self:_refreshAnnotationOverlay()
    if context.store:get(context.book_id, "meta", "enabled")
        and not context.store:get(context.book_id, "manual_only", context.document_key) then
        -- Only already cached chapters are matched automatically on open.
        -- Network work follows the explicit sync/prefetch path.
        local cached = {}
        local sources = context.store:list(context.book_id, "source_status")
        local partials = context.store:list(context.book_id, "download")
        for _, chapter in ipairs(context.chapters) do
            local uid = Chapters.uid(chapter)
            local source = sources[uid]
            local key = context.store:projectionKey(context.document_key, uid)
            local status = context.statuses[key]
            local partial = partials[uid]
            if (source and (not status or status.revision ~= source.revision))
                or (partial and self:isNetworkConnected()) then
                cached[#cached + 1] = chapter
            end
        end
        if #context.chapters == 1 and #cached == 0 and self:isNetworkConnected()
            and context.binding.automatic and self:isAnnotationPrefetchEnabled()
            and not sources[Chapters.uid(context.chapters[1])] then
            cached = context.chapters
        end
        if #cached > 0 then self:_runAnnotationJob(context, {
            background = true, offline = not self:isNetworkConnected(), chapters = cached }) end
    end
end

function M:prefetchChapterAnnotations(book, chapter)
    local book_id = tostring(book.book_id or book.bookId)
    local store = self:_annotationStore()
    if not self:isAnnotationPrefetchEnabled()
        or not store:get(book_id, "meta", "enabled") then return end
    if store:get(book_id, "source_status", Chapters.uid(chapter)) then return end
    self:_runAnnotationJob({ book_id = book_id, book = book, binding = book,
        store = store, chapters = { chapter } }, { background = true, prefetch = true })
end

function M:isAnnotationPrefetchEnabled()
    return self.settings:get("cache").prefetch_annotations == true
end

function M:setAnnotationPrefetchEnabled(enabled)
    local cache = self.settings:get("cache")
    cache.prefetch_annotations = enabled == true
    self.settings:set("cache", cache)
    self.settings:flush()
    local request = self._external_annotation_sync
    if not enabled and request and request.prefetch then
        self:_cancelUnifiedAnnotationSync()
    end
    if not enabled then self._annotation_pending_prefetch = nil end
    return true
end

function M:chooseAnnotationChapters()
    if not self:_annotationBinding() then return self:bindExternalAnnotationsBook() end
    local function show()
        local context = self:_prepareAnnotationContext(self:isNetworkConnected())
        if not context or #context.chapters == 0 then
            self:showInfo(_("No matching chapters found.")); return
        end
        local selected, menu, items = {}, nil, {}
        local function selection()
            local result = {}
            for _, chapter in ipairs(context.chapters) do
                if selected[Chapters.uid(chapter)] then result[#result + 1] = chapter end
            end
            return result
        end
        local function start()
            local chapters = selection()
            if #chapters == 0 then return end
            if menu then UIManager:close(menu) end
            self:startUnifiedAnnotationSync({ chapters = chapters, offline = not self:isNetworkConnected() })
        end
        local current_index
        local document = self.ui and self.ui.document
        if document and type(document.getXPointer) == "function" then
            local ok, point = pcall(document.getXPointer, document)
            if ok then current_index = self:_annotationChapterIndex(context, point) end
        end
        -- Keep the action reachable on every page, including keyboard devices.
        local per_page = 8
        for index, chapter in ipairs(context.chapters) do
            if (index - 1) % (per_page - 1) == 0 then
                items[#items + 1] = { text_func = function()
                    return T(_("Match selected chapters (%1)"), tostring(#selection()))
                end, bold = true, separator = true,
                    select_enabled_func = function() return #selection() > 0 end, callback = start }
            end
            local uid = Chapters.uid(chapter)
            local title = chapter.title or uid
            local status = context.statuses[context.store:projectionKey(context.document_key, uid)]
            items[#items + 1] = { text_func = function()
                return (selected[uid] and "[✓] " or "[  ] ") .. title
            end, bold = current_index == index,
                mandatory_func = function() return status and _("Matched") or nil end,
                callback = function()
                    selected[uid] = not selected[uid]
                    if menu then menu:updateItems() end
                end }
        end
        local initial_page = current_index
            and math.floor((current_index - 1) / (per_page - 1)) + 1 or 1
        menu = self:showList(_("Choose chapters to match"), items, nil, {
            items_per_page = per_page,
            initial_page = initial_page,
        })
    end
    local context = self:_prepareAnnotationContext(false)
    if context and #context.chapters > 0 then return show() end
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
            self:startUnifiedAnnotationSync({ offline = not self:isNetworkConnected() }) end },
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
    local changes = {
        { kind = "manual_only", key = context.document_key, value = true },
        { kind = "display", key = context.document_key },
    }
    for _, chapter in ipairs(context.chapters) do
        local uid = Chapters.uid(chapter)
        -- Clearing is the explicit path for fetching fresh remote data. Remove
        -- this chapter's shared annotations and every document projection, but
        -- retain the original chapter text so quote recovery stays cheap.
        for _, kind in ipairs({ "source", "source_status", "download", "batch",
            "thought", "refresh", "projection", "matching", "status" }) do
            changes[#changes + 1] = { kind = kind, uid = uid }
        end
    end
    context.store:write(context.book_id, changes)
    context.statuses = {}
    context.generation = (context.generation or 0) + 1
    self:_refreshAnnotationOverlay()
    self:showTransientInfo(_("Underlines and thoughts cleared. Match again to download fresh data."), 3)
end

return M
