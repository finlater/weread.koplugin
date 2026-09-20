package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local scheduled, shown, notices, progress_titles, progress_updates, prevented, allowed = {}, {}, {}, {}, {}, 0, 0
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        close = function() end, setDirty = function() end, show = function(_self, widget) shown[#shown + 1] = widget end,
    }
end
package.preload["weread.lib.standby_guard"] = function()
    return { acquire = function() prevented = prevented + 1; return {} end,
        release = function() allowed = allowed + 1 end }
end
package.preload["ui/widget/confirmbox"] = function() return { new = function(_self, args) return args end } end
package.preload["weread.ui.download_dialog"] = function()
    return { new = function(_self, args)
        args.show = function() end; args.close = function() end
        args.setTitle = function(dialog, title)
            dialog.current_title = title
            progress_titles[#progress_titles + 1] = title
            progress_updates[#progress_updates + 1] = {
                title = title,
                progress = dialog.current_progress,
            }
        end
        args.reportProgress = function(dialog, progress)
            dialog.current_progress = progress
        end
        return args
    end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return { reader_open_perf = function() return 0 end,
        tr = function(s) return s end, T = function(s, ...) local v = {...}
        return (s:gsub("%%(%d+)", function(i) return tostring(v[tonumber(i)]) end)) end }
end
local Controller = require("weread.ui.annotation_sync_controller")
local cache, calls, applied = { show_annotations = true }, 0, 0
local host = {
    _reader_session_gen = 1,
    ui = { document = { file = "single", getXPointer = function() return "0" end,
        findAllText = function() return { { start = "0", ["end"] = "1" } } end,
        compareXPointers = function(_self, a, b) return a == b and 0 or a < b and 1 or -1 end } },
    client = { get_chapter_underlines = function() calls = calls + 1
        return true, { underlines = { { range = "0-1", markText = "a" } } } end,
        build_chapter_review_batches = function(_self, ranges)
            return { { { range = ranges[1] } } }
        end,
        get_chapter_reviews_batch = function()
            return true, { reviews = {} }
        end },
    settings = { get = function() return cache end, set = function() end, flush = function() end },
    _xpointer_overlay = { setRecords = function(self, records) self.records = records end,
        setEnabled = function() end },
    showInfo = function(_self, message) notices[#notices + 1] = message end,
    showTransientInfo = function() end,
    applyAnnotationVisibility = function() applied = applied + 1 end,
    requireLogin = function() return true end,
    isNetworkConnected = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback() end,
    _xpointerOverlayPrototypeAvailable = function() return true end,
}
host.prefetch_worker = {
    available = function() return true end,
    start = function(_self, options)
        local handle = {}
        if options.on_launch then options.on_launch(123, 96 * 1024) end
        local emitted = {}
        local ok, value = pcall(options.task, {
            checkCancelled = function() end,
            emit = function(state)
                emitted[#emitted + 1] = state
                if options.on_progress then options.on_progress(state) end
            end,
            sleep = function() end,
        })
        options.on_done(ok and { ok = true, value = value }
            or { ok = false, error = value })
        return true, handle
    end,
    cancel = function() return true end,
}
for k,v in pairs(Controller) do host[k] = v end
local store = helper.new()
host.annotation_store = store
host.external_annotations_db = store.legacy
local context = { path = "single", book_id = "book", document_key = "single", store = store,
    binding = { book_id = "book", title = "fixture" }, statuses = {},
    chapters = { { chapterUid = "1" } }, ranges = {} }
host._annotation_context = context
host._annotationBinding = function() return context.binding end
host._prepareAnnotationContext = function() return context end
host._usesUnifiedAnnotations = function() return true end
local function drain()
    for _ = 1, 1000 do
        if #scheduled == 0 then return end
        table.remove(scheduled, 1)()
    end
    error("scheduler did not settle")
end
assert(not host:_annotationsVisibleForCurrentDocument(),
    "an unmatched clean document must not appear to have visible annotations")
assert(host:ensureAnnotationDisplay() and #shown == 1 and calls == 0,
    "unmatched display must ask before starting network work")
shown[1].ok_callback()
drain()
assert(calls == 1 and #host._xpointer_overlay.records == 1)
assert(store:get("book", "meta", "enabled") == true)
assert(not host:isAnnotationPrefetchEnabled(),
    "annotation prefetch must default to off")
assert(host:setAnnotationPrefetchEnabled(true)
        and cache.prefetch_annotations == true
        and host:isAnnotationPrefetchEnabled(),
    "annotation prefetch preference was not enabled globally")
assert(prevented == allowed and prevented == 1, "standby guard leaked after completion")
assert(applied == 1 and store:get("book", "display", "single"))
assert(host:_annotationsVisibleForCurrentDocument(),
    "a matched document with the display preference enabled must appear visible")
cache.show_annotations = false
assert(not host:_annotationsVisibleForCurrentDocument(),
    "the document must appear hidden when the display preference is disabled")
cache.show_annotations = true
local titles = table.concat(progress_titles, "\n")
assert(titles:find("Downloading thoughts 1/1 · chapter 1/1", 1, true),
    "thought download progress did not expose item counts")
assert(titles:find("Saving thoughts 1/1 · chapter 1/1", 1, true),
    "thought persistence did not expose item counts")
assert(titles:find("Matching underlines 1/1 · chapter 1/1", 1, true),
    "matching progress did not expose item counts")
local thought_progress_moved = false
for _, update in ipairs(progress_updates) do
    if update.title == "Downloading thoughts 1/1 · chapter 1/1"
        and update.progress == 0.25 then
        thought_progress_moved = true
        break
    end
end
assert(thought_progress_moved,
    "thought item progress did not advance the chapter progress bar")
-- Cancel before a queued request and ensure stale callbacks cannot run.
host:_runAnnotationJob(context, { refresh = true })
host:_cancelUnifiedAnnotationSync()
drain()
assert(calls == 1 and prevented == allowed)
-- A new reader session must invalidate callbacks even when path is unchanged.
host:_runAnnotationJob(context, { refresh = true })
host._reader_session_gen = 2
drain()
assert(calls == 1 and prevented == allowed)
-- Prefetch shares source data and never touches the open document.
cache.auto_prefetch_next_chapter = true
host:prefetchChapterAnnotations({ book_id = "book" }, { chapterUid = "2" })
drain()
assert(calls == 2 and store:get("book", "source", "2"))
assert(not store:get("book", "projection", "single:2"))
-- Turning off preparation suppresses future annotation requests.
host:setAnnotationPrefetchEnabled(false)
host:prefetchChapterAnnotations({ book_id = "book" }, { chapterUid = "3" })
drain()
assert(calls == 2)
-- A legacy completed source is retained until an explicit user sync. Prefetch
-- must not decode it or start an automatic network-backed rebuild.
host:setAnnotationPrefetchEnabled(true)
store:put("book", "source", "3", { chapter_uid = "3", underlines = {}, reviews = {} }, "3")
store:put("book", "source_status", "3", { revision = "legacy", total = 0 }, "3")
host:prefetchChapterAnnotations({ book_id = "book" }, { chapterUid = "3" })
drain()
assert(calls == 2 and not store:get("book", "source_status", "3").persistence_version,
    "prefetch rebuilt an old completed source automatically")
context.chapters, context.ranges = { { chapterUid = "3" } }, {}
store:put("book", "meta", "enabled", true)
    local legacy_notice, calls_before_legacy = nil, calls
    local original_transient_info = host.showTransientInfo
    host.showTransientInfo = function(_self, message) legacy_notice = message end
    host:onUnifiedAnnotationsReady()
    drain()
    assert(calls == calls_before_legacy
        and legacy_notice == "Thought data format has been upgraded. Match again to download current data.",
        "opening an old cache did not stay local with a rematch notice")
    -- Prefetch defaults to off; the upgrade notice must not depend on it.
    host:setAnnotationPrefetchEnabled(false)
    legacy_notice = nil
    local calls_before_off_notice = calls
    host:onUnifiedAnnotationsReady()
    drain()
    assert(calls == calls_before_off_notice
        and legacy_notice == "Thought data format has been upgraded. Match again to download current data.",
        "opening an old cache with prefetch disabled did not show the rematch notice")
    host:setAnnotationPrefetchEnabled(true)
    host.showTransientInfo = original_transient_info
    store:put("book", "source", "3", nil)
    store:put("book", "source_status", "3", nil)
-- Multi-select keeps source catalog order, including noncontiguous choices.
context.chapters = { { chapterUid = "1" }, { chapterUid = "2" }, { chapterUid = "3" } }
local picker_options, chosen
package.preload["weread.ui.annotation_chapter_picker"] = function()
    return { show = function(options) picker_options = options; return options end }
end
host.startUnifiedAnnotationSync = function(_self, options)
    assert(options.clear_existing and not options.offline)
    chosen = options.chapters
end
context.catalog = context.chapters
host:chooseAnnotationChapters()
local model = picker_options.model
model:toggle(model.by_uid["3"]); model:toggle(model.by_uid["1"])
picker_options.on_select(model:selection())
assert(#chosen == 2 and chosen[1].chapterUid == "1" and chosen[2].chapterUid == "3",
    "chapter picker must allow selecting completed chapters again")
-- Current chapter uses local bounds, independent of remote UID numbering.
context.chapters, context.ranges = {}, {}
local starts = { 0, 8, 19, 33, 48, 65, 79, 91, 103, 1000, 1300, 1600, 1900, 2200, 2500 }
for index, start in ipairs(starts) do
    local uid = tostring(100 + index)
    context.chapters[index] = { chapterUid = uid }
    context.ranges[uid] = { start_xpointer = tostring(start) }
end
host.ui.document.getXPointer = function() return "1120" end
host.ui.document.compareXPointers = function(_self, a, b)
    a, b = tonumber(a), tonumber(b)
    return a == b and 0 or a < b and 1 or -1
end
host:chooseAnnotationChapters()
assert(picker_options.model.current.chapter.chapterUid == "110",
    "chapter picker did not locate the current local chapter")
-- Matching one selected chapter must activate its projection immediately;
-- waiting for every mapped chapter leaves valid underlines invisible.
context.chapters = { { chapterUid = "1" }, { chapterUid = "2" } }
context.ranges = {}
context.statuses = {}
host._unified_annotations_active = false
store:put("book", "display", "single", nil)
local applied_before_partial = applied
host:_runAnnotationJob(context, { chapters = { context.chapters[1] }, refresh = true })
drain()
assert(store:get("book", "display", "single") == true
    and host._unified_annotations_active == true
    and applied == applied_before_partial + 1,
    "a successfully matched selected chapter did not activate its projection")
store:put("book", "display", "single", nil)
host:onUnifiedAnnotationsReady()
assert(store:get("book", "display", "single") == true,
    "an existing partial projection was not activated when reopening the book")
-- Opening a book never matches positions. Downloads need both switches and
-- must remain in the worker, including old checkpoints and refresh attempts.
do
    local preferences, online = {}, true
    local launched, network, overlays, cancel_count = {}, {}, 0, 0
    local automatic_context = {
        path = "automatic", book_id = "automatic", document_key = "automatic",
        binding = { automatic = true }, store = store, statuses = {}, ranges = {},
        chapters = { { chapterUid = "partial" }, { chapterUid = "cached" }, { chapterUid = "new" } },
    }
    local automatic = setmetatable({
        _reader_session_gen = 1,
        settings = {
            get = function(_self, key, default) return key == "cache" and preferences or default end,
            set = function() end, flush = function() end,
        },
        ui = { document = { file = "automatic",
            findAllText = function() error("automatic position matching") end } },
        client = {
            get_chapter_underlines = function(_self, _book, uid)
                network[#network + 1] = "underlines:" .. uid
                return true, { underlines = {} }
            end,
            build_chapter_review_batches = function(_self, ranges)
                local batches = {}
                for _, range in ipairs(ranges) do batches[#batches + 1] = { { range = range } } end
                return batches
            end,
            get_chapter_reviews_batch = function(_self, _book, _uid, batch)
                network[#network + 1] = "thoughts:" .. batch[1].range
                return true, { reviews = {} }
            end,
        },
        _prepareAnnotationContext = function() return automatic_context end,
        _usesUnifiedAnnotations = function() return true end,
        _refreshAnnotationOverlay = function() overlays = overlays + 1 end,
        isNetworkConnected = function() return online end,
    }, { __index = Controller })
    local worker_available = true
    automatic.prefetch_worker = {
        available = function() return worker_available end,
        start = function(_self, options)
            launched[#launched + 1] = options
            options.on_launch(123, 96 * 1024)
            return true, options
        end,
        cancel = function(_self, handle)
            cancel_count = cancel_count + 1
            handle.on_done({ ok = false, cancelled = true })
            return true
        end,
    }
    store:put("automatic", "meta", "enabled", true)
    store:put("automatic", "download", "partial", { revision = "1", next_batch = 2,
        underlines = { { range = "0-1", markText = "a" }, { range = "2-3", markText = "b" } } }, "partial")
    store:put("automatic", "batch", "partial:1", {}, "partial")
    store:put("automatic", "source_status", "cached", { revision = "1" }, "cached")
    store:put("automatic", "matching", "automatic:cached", { next_index = 17 }, "cached")
    local queued_before = #scheduled
    for _, switches in ipairs({ { false, false }, { true, false }, { false, true } }) do
        preferences.auto_prefetch_next_chapter, preferences.prefetch_annotations = unpack(switches)
        automatic:onUnifiedAnnotationsReady()
        automatic:prefetchChapterAnnotations({ book_id = "automatic" }, { chapterUid = "new" })
        automatic:_runAnnotationJob(automatic_context, { background = true })
        assert(#launched == 0 and #network == 0 and #scheduled == queued_before,
            "disabled automatic work reached a worker or the UI scheduler")
    end
    preferences.auto_prefetch_next_chapter, preferences.prefetch_annotations = true, true
    online = false
    automatic:onUnifiedAnnotationsReady()
    assert(#launched == 0)
    online = true
    automatic:onUnifiedAnnotationsReady()
    assert(#launched == 1 and #network == 0 and #scheduled == queued_before and overlays == 5)
    local result = launched[1].task({ checkCancelled = function() end,
        emit = function(state) assert(state.stage ~= "match") end, sleep = function() end })
    launched[1].on_done({ ok = true, value = result })
    assert(#network == 1 and network[1] == "thoughts:2-3",
        "automatic resume redownloaded completed batches or started untouched chapters")
    assert(store:get("automatic", "source_status", "partial")
        and not store:get("automatic", "download", "partial")
        and not store:get("automatic", "projection", "automatic:partial")
        and store:get("automatic", "matching", "automatic:cached").next_index == 17,
        "automatic download changed document positions or lost a matching checkpoint")
    automatic:onUnifiedAnnotationsReady()
    assert(#launched == 1, "completed source triggered automatic matching")

    -- An interrupted refresh keeps the old source, but still needs resuming.
    store:put("automatic", "refresh", "cached", true, "cached")
    automatic:onUnifiedAnnotationsReady()
    assert(#launched == 2)
    automatic:_runAnnotationJob(automatic_context, { background = true })
    automatic:setAnnotationPrefetchEnabled(false)
    assert(cancel_count == 1 and not automatic._external_annotation_sync
        and not automatic._annotation_pending_prefetch and #launched == 2,
        "disabling thought prefetch allowed queued automatic work to launch")

    preferences.prefetch_annotations = true
    automatic:onUnifiedAnnotationsReady()
    automatic:_runAnnotationJob(automatic_context, { background = true })
    preferences.auto_prefetch_next_chapter = false
    automatic:cancelAnnotationPrefetch()
    assert(cancel_count == 2 and not automatic._external_annotation_sync
        and not automatic._annotation_pending_prefetch,
        "disabling chapter prefetch did not cancel annotations")
    assert(store:get("automatic", "refresh", "cached")
        and store:get("automatic", "source_status", "partial"), "cancellation discarded saved data")

    preferences.auto_prefetch_next_chapter = true
    worker_available = false
    automatic:onUnifiedAnnotationsReady()
    assert(#launched == 3 and #network == 1 and #scheduled == queued_before
        and not automatic._external_annotation_sync, "worker unavailable fell back to the UI thread")
    worker_available = true
    store:put("automatic", "manual_only", "automatic", true)
    automatic:onUnifiedAnnotationsReady()
    assert(#launched == 3, "opening after clearing started an automatic refresh")
    store:put("automatic", "manual_only", "automatic", nil)

    -- Changing preferences must not cancel a manual operation, including one
    -- already waiting for the background child to exit.
    automatic.prefetch_worker.cancel = function() return true end
    automatic:onUnifiedAnnotationsReady()
    automatic:_runAnnotationJob(automatic_context, { offline = true })
    automatic:setAnnotationPrefetchEnabled(false)
    assert(automatic._annotation_pending_prefetch
        and not automatic._annotation_pending_prefetch.options.prefetch)
    launched[4].on_done({ ok = false, cancelled = true })
    local manual = automatic._external_annotation_sync
    assert(manual and not manual.prefetch)
    automatic:cancelAnnotationPrefetch()
    assert(automatic._external_annotation_sync == manual and not manual.cancelled)
    automatic:_cancelUnifiedAnnotationSync()
    drain()
    assert(prevented == allowed, "automatic cancellation leaked a standby guard")
end
-- Clearing is the explicit refresh path: shared annotations and every file's
-- coordinates are removed book-wide, even for chapters absent from the current
-- local edition. Cached chapter text and the local-book binding remain reusable.
context.chapters = { { chapterUid = "1" }, { chapterUid = "2" }, { chapterUid = "3" } }
context.ranges = {}
store:put("book", "original", "1", { spans = {} }, "1")
store:put("book", "original", "99", { spans = {} }, "99")
store:put("book", "projection", "other:1", { records = {} }, "1")
store:put("book", "projection", "stale:99", { records = { {} } }, "99")
store:put("book", "thought", "99:range", { { content = "stale" } }, "99")
store:put("book", "source", "99", { underlines = { {} } }, "99")
store:put("book", "display", "old-document-key", true)
store:put("book", "manual_only", "old-document-key", true)
helper.legacy_entries.single = {
    binding = { book_id = "book", title = "fixture" },
    records = { { chapter_uid = "99", pos0 = "0", pos1 = "1" } },
}
host:clearUnifiedAnnotationProjections()
assert(not store:get("book", "source", "1")
    and not store:get("book", "projection", "single:1")
    and not store:get("book", "projection", "other:1")
    and not store:get("book", "source", "99")
    and not store:get("book", "thought", "99:range")
    and not store:get("book", "projection", "stale:99"),
    "clearing did not remove all book-wide annotations and coordinates")
assert(not store:get("book", "display", "old-document-key")
    and not store:get("book", "manual_only", "old-document-key")
    and store:get("book", "manual_only", "single") == true,
    "clearing retained a stale document display key")
assert(store:get("book", "original", "1") and store:get("book", "original", "99"),
    "clearing discarded reusable original chapter text")
assert(helper.legacy_entries.single
    and helper.legacy_entries.single.binding.book_id == "book"
    and helper.legacy_entries.single.records == nil,
    "clearing did not remove legacy records while preserving the binding")
-- Offline continuation shows a translated business message, with no Lua path,
-- and stops at the first chapter that needs downloading.
host.startUnifiedAnnotationSync = Controller.startUnifiedAnnotationSync
host.isNetworkConnected = function() return false end
context.chapters = { { chapterUid = "uncached" } }
local previous_calls, previous_notices = calls, #notices
host:startUnifiedAnnotationSync({ offline = true })
drain()
assert(calls == previous_calls and #notices == previous_notices + 1)
assert(notices[#notices] == "Connect to the network to download annotation data. Saved matching progress will be reused.")
assert(prevented == allowed, "offline pause leaked the standby guard")
-- Exercise actual context preparation, native-menu choices and persistence
-- against SQLite, starting with no automatic title matches.
do
    package.preload["libs/libkoreader-lfs"] = function() return { attributes = function() return {} end } end
    local chapter_catalog = { { chapterUid = "a", title = "Remote A" }, { chapterUid = "b", title = "Remote B" } }
    local local_toc = { { title = "Part", xpointer = "0", depth = 1 },
        { title = "Local A", xpointer = "10", depth = 2 },
        { title = "Local B", xpointer = "20", depth = 2 } }
    store:put("manual", "meta", "catalog", chapter_catalog)
    local mapping_host = setmetatable({
        _reader_session_gen = 1, _annotation_context = false, _external_annotation_sync = false,
        ui = { document = { file = "manual.epub", getToc = function() return local_toc end,
            getXPointer = function() return "10" end, compareXPointers = host.ui.document.compareXPointers } },
        _prepareAnnotationContext = Controller._prepareAnnotationContext,
        _annotationBinding = function() return { book_id = "manual", title = "Manual" } end,
        isNetworkConnected = function() return false end,
        settings = { get = function() return {} end },
        _xpointer_overlay = { records = {}, setRecords = function(self, records) self.records = records end },
    }, { __index = host })
    local menu_items, menu_options, updated_model, closed_menu
    local menu_token = {}
    local manager = require("ui/uimanager")
    local close = manager.close
    manager.close = function(_self, widget) closed_menu = widget end
    local picker = require("weread.ui.annotation_chapter_picker")
    local show_picker = picker.show
    picker.show = function(options)
        if not options.choices then return show_picker(options) end
        menu_items, menu_options = options.choices, options
        return menu_token
    end
    local network_calls = calls
    mapping_host:chooseAnnotationChapters()
    local options = picker_options
    assert(#options.model.nodes == 3 and options.model.count == 0 and #options.model.chapters == 0)
    options.on_edit(options.model.nodes[2], function(result) updated_model = result end)
    assert(#menu_items == 2 and menu_items[1].select_enabled)
    menu_items[1].callback()
    assert(updated_model.by_uid.a.xpointer == "10" and updated_model.count == 0 and calls == network_calls)
    assert(closed_menu == menu_token, "choosing a remote chapter did not close its native menu")
    local saved_context = mapping_host._annotation_context
    local doc_key = saved_context.document_key
    mapping_host._annotation_context = nil
    mapping_host:chooseAnnotationChapters()
    options = picker_options
    assert(options.model.by_uid.a.xpointer == "10" and options.model.count == 0, "mapping did not survive reopen")
    options.on_edit(options.model.nodes[3], function(result) updated_model = result end)
    assert(menu_items[1].select_enabled == false and menu_items[1].detail:find("Local A", 1, true)
        and menu_items[1].text == "Remote A" and menu_items[1].status == "Already linked",
        "occupied mapping must be a separate detail, not part of the chapter title")
    menu_items[1].callback()
    assert(not store:get("manual", "chapter_mapping", doc_key)["20"], "occupied chapter was reused")
    menu_items[2].callback()
    assert(updated_model.by_uid.b.xpointer == "20")
    -- Successful zero-thought chapters are retrieved; refresh checkpoints and
    -- mismatched revisions must never display that status.
    local saved = mapping_host._annotation_context
    local key = store:projectionKey(doc_key, "a")
    store:put("manual", "source_status", "a", { revision = "7", total = 0 }, "a")
    store:put("manual", "status", key, { revision = "7", stats = { total = 0, located = 0 },
        matcher_version = require("weread.lib.external_annotations").MATCHER_VERSION,
        range_key = require("weread.lib.annotation_chapters").rangeKey(saved.ranges.a) }, "a")
    mapping_host._annotation_context = nil
    saved = mapping_host:_prepareAnnotationContext(false)
    assert(mapping_host:_annotationSelectionModel(saved).by_uid.a.fetched)
    store:put("manual", "refresh", "a", true, "a")
    assert(not mapping_host:_annotationSelectionModel(saved).by_uid.a.fetched)
    store:put("manual", "refresh", "a", nil)
    store:put("manual", "source_status", "a", { revision = "8" }, "a")
    assert(not mapping_host:_annotationSelectionModel(saved).by_uid.a.fetched)
    -- Clearing a mapping immediately invalidates old anchors and persists an
    -- explicit exclusion, so an automatic title match cannot restore it.
    local_toc[2].title = "Remote A"
    store:put("manual", "projection", key, { records = { { pos0 = "11" } } }, "a")
    store:put("manual", "status", key, nil)
    store:put("manual", "matching", key, { partial = true }, "a")
    mapping_host._annotation_context = nil
    mapping_host:chooseAnnotationChapters()
    options = picker_options
    options.on_edit(options.model.by_uid.a, function(result) updated_model = result end)
    assert(#menu_items == 2 and menu_items[1].current and menu_options.on_remove,
        "remove action must be separate from catalog choices")
    menu_options.on_remove()
    assert(not updated_model.by_uid.a and not store:get("manual", "projection", key)
        and not store:get("manual", "matching", key), "statusless old coordinates survived a mapping change")
    assert(store:get("manual", "chapter_mapping", doc_key)["10"] == false)
    assert(#mapping_host._xpointer_overlay.records == 0)
    mapping_host._annotation_context = nil
    assert(not mapping_host:_prepareAnnotationContext(false).ranges.a)
    -- A menu left open across a reader-session change cannot write old choices.
    mapping_host:chooseAnnotationChapters()
    options = picker_options
    options.on_edit(options.model.nodes[2], function() error("stale menu saved") end)
    mapping_host._reader_session_gen = 2
    menu_items[1].callback()
    assert(store:get("manual", "chapter_mapping", doc_key)["10"] == false)
    assert(calls == network_calls, "manual matching performed network work")
    manager.close = close
    picker.show = show_picker
end
-- Foreground HTTP must yield outside Sync.thread, so cancel can terminate the
-- suspended request without resuming the pipeline early or committing late data.
do
    local pending, resume_child, killed, spawned = nil, nil, 0, 0
    local fail_start = false
    local trapper = {
        wrap = function(_self, callback)
            local ok, err = coroutine.resume(coroutine.create(callback))
            assert(ok, err)
        end,
        dismissableRunInSubprocess = function(_self, task, dialog)
            if fail_start then return false end
            assert(not pending, "overlapping annotation workers")
            spawned = spawned + 1
            pending = task
            local co = coroutine.running()
            dialog.dismiss_callback = function()
                killed, pending = killed + 1, nil
                local ok, err = coroutine.resume(co, false)
                assert(ok, err)
            end
            resume_child = function(result)
                pending = nil
                local ok, err = coroutine.resume(co, true, result)
                assert(ok, err)
            end
            return coroutine.yield()
        end,
    }
    package.loaded["ffi/util"] = { runInSubProcess = function() end }
    package.loaded["ui/trapper"] = trapper
    local WorkerSettings = require("weread.lib.worker_settings")
    local capture = WorkerSettings.capture
    local returned_auth
    -- The fake child runs in-process; real capture changes are fork-isolated.
    WorkerSettings.capture = function() return function() return returned_auth end end
    local function complete_child()
        assert(pending, "no suspended request")
        local result = pending()
        resume_child(result)
        drain()
    end
    local requested, updates = {}, 0
    local auth = { cookies = { session = "before" } }
    host.settings = { get = function(_self, key, default) return auth[key] or default end,
        update_auth = function() updates = updates + 1 end }
    host.isNetworkConnected = function() return true end
    host._reader_session_gen = 3
    local fail_http, missing = false, false
    host.client = {
        get_chapter_underlines = function()
            requested[#requested + 1] = "underlines"
            if fail_http then return false, nil, "fixture failure" end
            return true, { underlines = { { range = "0-1", markText = not missing and "a" or nil },
                { range = "2-3", markText = "b" } } }
        end,
        build_chapter_review_batches = function(_self, ranges) return { { ranges[1] }, { ranges[2] } } end,
        get_chapter_reviews_batch = function(_self, _book, _uid, batch)
            requested[#requested + 1] = "thoughts:" .. batch[1]
            return true, { reviews = {} }
        end,
    }
    local function start(uid, options)
        context = { path = "single", book_id = "cancel", document_key = "cancel-key", store = store,
            binding = { book_id = "cancel", title = "Cancel" }, statuses = {},
            chapters = type(uid) == "table" and uid or { { chapterUid = uid } }, ranges = {} }
        host._annotation_context = context
        host:_runAnnotationJob(context, options)
        local request = host._external_annotation_sync
        drain()
        return request
    end
    local before_notices = #notices
    local request = start("cancel-underlines")
    assert(pending and #requested == 0, "HTTP ran before returning control to the UI")
    request.progress.buttons[1][1].callback()
    drain()
    assert(killed == 1 and not pending and not host._external_annotation_sync)
    assert(request.job.cancelled and not request.progress.dismiss_callback and #requested == 0)
    assert(#notices == before_notices and prevented == allowed, "cancel leaked guards or reported an error")

    request = start("cancel-batch")
    complete_child() -- underlines
    complete_child() -- first thoughts batch
    assert(pending and store:get("cancel", "download", "cancel-batch").next_batch == 2)
    assert(store:get("cancel", "batch", "cancel-batch:1"))
    request.progress.buttons[1][1].callback()
    drain()
    assert(killed == 2 and not store:get("cancel", "batch", "cancel-batch:2"))
    assert(not store:get("cancel", "source", "cancel-batch"))
    start("cancel-batch")
    complete_child() -- resumes the second batch, without refetching underlines
    assert(not pending and not host._external_annotation_sync)
    assert(table.concat(requested, ",") == "underlines,thoughts:0-1,thoughts:2-3")
    assert(store:get("cancel", "status", "cancel-key:cancel-batch"))

    missing = true
    request = start("cancel-source")
    complete_child(); complete_child(); complete_child()
    assert(pending and request.progress.current_title:find("source text", 1, true))
    request.progress.buttons[1][1].callback()
    drain()
    assert(killed == 3 and not store:get("cancel", "original", "cancel-source"))
    assert(store:get("cancel", "download", "cancel-source").next_batch == 3)
    require("weread.lib.content").fetch_chapter_xhtml = function(_client, _settings, book)
        book._content_format = "txt"
        store:put("cancel", "original", "cancel-source",
            require("weread.lib.annotation_source").index("<p>a b</p>"), "cancel-source")
        return "unused XHTML"
    end
    start("cancel-source")
    complete_child()
    assert(not pending and store:get("cancel", "status", "cancel-key:cancel-source"))
    missing = false

    -- A response received after a reader-session change cannot be committed.
    start("stale-session")
    host._reader_session_gen = host._reader_session_gen + 1
    complete_child()
    assert(not host._external_annotation_sync and not store:get("cancel", "download", "stale-session"))
    -- Replacing a running request kills it before the next dialog takes over.
    request = start("replaced")
    local next_request = start("replacement")
    assert(request.cancelled and pending and host._external_annotation_sync == next_request)
    host:_cancelUnifiedAnnotationSync()
    drain()
    assert(not pending and prevented == allowed)

    -- Preserve false/nil/error across the subprocess response and retry budget.
    fail_http = true
    local before_requests = #requested
    start("http-failure")
    for _attempt = 1, 3 do complete_child() end
    assert(not pending and #requested == before_requests + 3 and not host._external_annotation_sync)
    assert(not store:get("cancel", "download", "http-failure") and prevented == allowed)
    fail_http, fail_start = false, true
    start("launch-failure")
    assert(not pending and not host._external_annotation_sync and prevented == allowed)
    fail_start = false

    -- A later worker failure must not hide already committed chapters. This
    -- also covers old downloaded books whose embedded annotations are gated.
    host._unified_annotations_active = false
    store:put("cancel", "display", "cancel-key", nil)
    local partial = { { chapterUid = "partial-1" }, { chapterUid = "partial-2" } }
    start(partial)
    context.binding.automatic = true
    complete_child(); complete_child(); complete_child()
    assert(pending and store:get("cancel", "status", "cancel-key:partial-1"))
    assert(host._unified_annotations_active and store:get("cancel", "display", "cancel-key")
        and #host._xpointer_overlay.records > 0, "completed chapter hidden until the entire job finishes")
    resume_child(nil); drain()
    assert(not host._external_annotation_sync and #host._xpointer_overlay.records > 0
        and store:get("cancel", "source", "partial-1"), "worker failure lost completed chapter")
    local resumed_from = #requested
    start(partial)
    complete_child(); complete_child(); complete_child()
    assert(not pending and not host._external_annotation_sync and #requested == resumed_from + 3,
        "resuming refetched the completed chapter")

    -- A concurrent login change wins over auth captured by an older worker.
    returned_auth = { cookies = { session = "old-child" } }
    start("new-login")
    auth.cookies = { session = "new-login" }
    complete_child()
    assert(updates == 0)
    returned_auth = nil
    host:_cancelUnifiedAnnotationSync()
    drain()
    assert(spawned > killed and prevented == allowed)
    WorkerSettings.capture = capture
end

-- A user-initiated sync must actually rebuild a legacy (pre-persistence)
-- chapter instead of silently skipping it: regression for `reset_legacy`
-- never reaching the Sync job. The worker block above left its auth-keyed
-- settings and request-tracking client behind, so restore plain fixtures.
package.loaded["ffi/util"], package.loaded["ui/trapper"] = nil, nil
host.settings = { get = function() return cache end, set = function() end, flush = function() end }
host.client = {
    get_chapter_underlines = function() calls = calls + 1
        return true, { underlines = { { range = "0-1", markText = "a" } } } end,
    build_chapter_review_batches = function(_self, ranges)
        return { { { range = ranges[1] } } }
    end,
    get_chapter_reviews_batch = function()
        return true, { reviews = {} }
    end,
}
context = { path = "single", book_id = "legacy-sync", document_key = "single", store = store,
    binding = { book_id = "legacy-sync", title = "fixture" }, statuses = {},
    chapters = { { chapterUid = "9" } }, ranges = {} }
host._annotation_context = context
store:put("legacy-sync", "source", "9", {
    book_id = "legacy-sync", chapter_uid = "9",
    underlines = { { range = "1-2", markText = "alpha" } },
    reviews = { { range = "1-2", pageReviews = { { review = { content = "old thought" } } } } },
}, "9")
store:put("legacy-sync", "source_status", "9", { revision = "legacy", total = 1 }, "9")
local legacy_persistence_version = require("weread.lib.annotation_sync").PERSISTENCE_VERSION
local calls_before_explicit_sync = calls
host:startUnifiedAnnotationSync({ offline = false })
drain()
local rebuilt_legacy_source = store:get("legacy-sync", "source", "9")
assert(calls > calls_before_explicit_sync
        and rebuilt_legacy_source and #(rebuilt_legacy_source.reviews or {}) == 0
        and store:get("legacy-sync", "source_status", "9").persistence_version == legacy_persistence_version,
    "an explicit sync did not rebuild the legacy chapter with bounded persistence")

-- A store busy with a cancelled prefetch worker finishing its last write must
-- not abort the reader-ready path: the display flag write is best effort.
host:setAnnotationPrefetchEnabled(false)
context.statuses = {
    [store:projectionKey(context.document_key, "9")] = { stats = { total = 1, located = 1 } },
}
local original_put = store.put
store.put = function() error("ljsqlite3[busy] database is locked") end
local ready_ok = pcall(function() host:onUnifiedAnnotationsReady() end)
store.put = original_put
assert(ready_ok, "a failed display flag write aborted the reader-ready path")

-- Pausing an explicit legacy rebuild before its first network request must
-- drop the deleted projection from the in-memory summary and refresh the
-- overlay: the legacy deletion path only notified the controller for
-- `clear_existing` before this fix.
do
    context = { path = "single", book_id = "legacy-pause", document_key = "single", store = store,
        binding = { book_id = "legacy-pause", title = "fixture" }, statuses = {},
        chapters = { { chapterUid = "9" } }, ranges = {}, generation = 1 }
    host._annotation_context = context
    local pause_key = store:projectionKey("single", "9")
    store:put("legacy-pause", "source", "9", {
        book_id = "legacy-pause", chapter_uid = "9",
        underlines = { { range = "1-2", markText = "alpha" } },
        reviews = { { range = "1-2", pageReviews = { { review = { content = "old thought" } } } } },
    }, "9")
    store:put("legacy-pause", "source_status", "9", { revision = "legacy", total = 1 }, "9")
    store:put("legacy-pause", "projection", pause_key,
        { records = { { range = "1-2", markText = "alpha" } } }, "9")
    store:put("legacy-pause", "status", pause_key,
        { revision = "legacy", matcher_version = 1, range_key = "" }, "9")
    context.statuses[pause_key] = { stats = { total = 1, located = 1 } }
    host._xpointer_overlay.records = { { range = "1-2", markText = "alpha" } }
    host._xpointer_overlay._annotation_window = "1:1:1"
    local calls_before_pause = calls
    host:startUnifiedAnnotationSync({ offline = false })
    assert(#scheduled >= 1, "the legacy rebuild scheduled no task callback")
    table.remove(scheduled, 1)()
    assert(calls == calls_before_pause,
        "the paused legacy rebuild contacted the network before its checkpoint")
    assert(store:get("legacy-pause", "projection", pause_key) == nil,
        "the legacy projection was not deleted from the store")
    host:_refreshAnnotationOverlay()
    local paused_summary = host:_annotationSummary(context)
    assert(context.statuses[pause_key] == nil
            and paused_summary.chapters == 0 and paused_summary.located == 0
            and #host._xpointer_overlay.records == 0,
        "a paused legacy rebuild left stale statuses or overlay records behind")
    host:_cancelUnifiedAnnotationSync()
    drain()
    assert(prevented == allowed, "standby guard leaked after the paused legacy rebuild")
end

helper.cleanup()
print("annotation_sync_controller_spec: consent, completion, cancellation, sessions, prefetch and legacy rebuild passed")
