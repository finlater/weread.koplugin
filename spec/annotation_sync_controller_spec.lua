package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local scheduled, shown, notices, progress_titles, prevented, allowed = {}, {}, {}, {}, 0, 0
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
        args.setTitle = function(_dialog, title) progress_titles[#progress_titles + 1] = title end
        args.reportProgress = function() end
        return args
    end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s, ...) local v = {...}
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
local picker, chosen
host.showList = function(_self, _title, items) picker = items; return { updateItems = function() end } end
host.startUnifiedAnnotationSync = function(_self, options) chosen = options.chapters end
host:chooseAnnotationChapters()
picker[4].callback(); picker[2].callback(); picker[1].callback()
assert(#chosen == 2 and chosen[1].chapterUid == "1" and chosen[2].chapterUid == "3")
-- Clearing is the explicit refresh path: shared annotations and every file's
-- coordinates are removed, while cached chapter text remains reusable.
store:put("book", "original", "1", { spans = {} }, "1")
store:put("book", "projection", "other:1", { records = {} }, "1")
host:clearUnifiedAnnotationProjections()
assert(not store:get("book", "source", "1")
    and not store:get("book", "projection", "single:1")
    and not store:get("book", "projection", "other:1"),
    "clearing did not remove shared annotations and cross-file coordinates")
assert(store:get("book", "original", "1"),
    "clearing discarded reusable original chapter text")
helper.cleanup()
print("annotation_sync_controller_spec: consent, completion, cancellation, sessions and prefetch passed")
