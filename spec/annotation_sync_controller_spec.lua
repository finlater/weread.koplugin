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
        clearAnnotationState = function(self) self:setRecords({}) end,
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
assert(titles:find("Matching underlines 1/1 · chapter 1/1", 1, true),
    "matching progress did not expose item counts")
local thought_progress_moved = false
for _, update in ipairs(progress_updates) do
    if update.title == "Downloading thoughts 1/1 · chapter 1/1"
        and update.progress == 0.5 then
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
-- A normal sync handles only the chapter at the current reading position;
-- explicit selections from the chapter picker remain untouched.
local synced_chapters
host.startUnifiedAnnotationSync = Controller.startUnifiedAnnotationSync
local original_run_annotation_job = host._runAnnotationJob
host._runAnnotationJob = function(_self, _context, options) synced_chapters = options.chapters end
host:startUnifiedAnnotationSync({ offline = true })
assert(#synced_chapters == 1 and synced_chapters[1].chapterUid == "110",
    "default annotation sync did not limit work to the current chapter")
host:startUnifiedAnnotationSync({ offline = true, all_chapters = true })
assert(#synced_chapters == #context.chapters,
    "explicit whole-book sync did not retain every chapter")
context.ranges["110"].end_xpointer = "1150"
host.ui.document.getXPointer = function() return "1200" end
synced_chapters = nil
local notices_before_gap = #notices
host:startUnifiedAnnotationSync({ offline = true })
assert(synced_chapters == nil and #notices == notices_before_gap + 1
        and notices[#notices] == "Current position is outside the matched chapters. Use “Choose chapters to match”.",
    "an unmapped reader position silently synced the preceding chapter")
context.ranges["110"].end_xpointer = nil
host.ui.document.getXPointer = function() return "1120" end
-- A single mapped chapter must not claim a position its explicit boundary has
-- already rejected: the reader may sit in an unmapped appendix.
context.chapters = { { chapterUid = "1" } }
context.ranges = { ["1"] = { start_xpointer = "0", end_xpointer = "100" } }
host.ui.document.getXPointer = function() return "150" end
synced_chapters = nil
local notices_before_single_gap = #notices
host:startUnifiedAnnotationSync({ offline = true })
assert(synced_chapters == nil and #notices == notices_before_single_gap + 1
        and notices[#notices] == "Current position is outside the matched chapters. Use “Choose chapters to match”.",
    "a single mapped chapter swallowed a position outside its boundary")
host.ui.document.getXPointer = function() return "1120" end
host._runAnnotationJob = original_run_annotation_job
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
-- Opening a book may display saved projections, but it never starts a sync.
do
    local sync_starts = 0
    local automatic_context = {
        path = "automatic", book_id = "automatic", document_key = "automatic",
        binding = { automatic = true }, store = store, statuses = {}, ranges = {},
        chapters = { { chapterUid = "cached" } },
    }
    local automatic = setmetatable({
        _reader_session_gen = 1,
        _annotationBinding = function() return automatic_context.binding end,
        _hasSavedAutomaticAnnotationData = function() return true end,
        _prepareAnnotationContext = function() return automatic_context end,
        _annotationSummary = function() return { located = 0 } end,
        _usesUnifiedAnnotations = function() return true end,
        _refreshAnnotationOverlay = function() end,
        _runAnnotationJob = function() sync_starts = sync_starts + 1 end,
    }, { __index = Controller })
    automatic:onUnifiedAnnotationsReady()
    assert(sync_starts == 0, "opening a book started an automatic annotation sync")
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
        _xpointer_overlay = { records = {}, setRecords = function(self, records) self.records = records end,
            clearAnnotationState = function(self) self:setRecords({}) end },
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
helper.cleanup()
print("annotation_sync_controller_spec: consent, completion, cancellation, sessions and prefetch passed")
