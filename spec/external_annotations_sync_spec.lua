-- Shared-book pipeline regressions, using the actual locator and SQLite store.
package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local Sync = require("weread.lib.annotation_sync")
local External = require("weread.lib.external_annotations")
local calls, matched = {}, {}
local empty, fail_batch = false, false
local client = {
    get_chapter_underlines = function(_self, _book, uid)
        calls[#calls + 1] = "u" .. uid
        return true, { underlines = empty and {} or {
            { range = "1-2", markText = "alpha" }, { range = "3-4", markText = "beta" } } }
    end,
    build_chapter_review_batches = function(_self, ranges)
        local batches = {}
        for _, range in ipairs(ranges) do batches[#batches + 1] = { range } end
        return batches
    end,
    get_chapter_reviews_batch = function(_self, _book, uid, batch)
        calls[#calls + 1] = "r" .. uid .. ":" .. batch[1]
        if fail_batch and batch[1] == "3-4" then return false, nil, "offline" end
        return true, { reviews = { { range = batch[1], pageReviews = {
            { review = { content = "thought", author = {} } } } } } }
    end,
}
local document = {
    findAllText = function(_self, quote)
        return { { start = quote == "alpha" and "10" or "20", ["end"] = quote == "alpha" and "15" or "25" } }
    end,
    compareXPointers = function(_self, a, b)
        if tonumber(a) < tonumber(b) then return 1 elseif tonumber(a) > tonumber(b) then return -1 else return 0 end
    end,
}
local function new(key, chapters, options)
    local args = { store = helper.new(), client = client, book_id = "book",
        document = document, document_key = key, chapters = chapters,
        on_chapter = function(uid) matched[#matched + 1] = uid end }
    for k, v in pairs(options or {}) do args[k] = v end
    return Sync:new(args)
end
local function finish(job)
    for _ = 1, 5000 do
        local done, state = job:step()
        if done == nil then return nil, state end
        if done then return true end
    end
    error("job failed to terminate")
end
local chapters = { { chapterUid = "1" }, { chapterUid = "2" } }
local job = new("single", chapters)
local store = helper.new()
for _ = 1, 100 do
    assert(job:step() ~= nil)
    if store:get("book", "batch", "1:1") then break end
end
assert(store:get("book", "batch", "1:1"), "first batch not persisted")
job.cancelled = true
local count = #calls
assert(finish(new("single", chapters)))
assert(calls[count + 1] == "r1:3-4", "resume must skip saved underlines and review batch")
assert(matched[1] == "1", "chapter one must commit before chapter two")
local next_u
for i, call in ipairs(calls) do if call == "u2" then next_u = i end end
assert(next_u and store:get("book", "projection", "single:1"))
count = #calls
assert(finish(new("full", chapters)))
assert(#calls == count, "opening full book re-downloaded single-chapter data")
assert(store:get("book", "projection", "full:1"), "full EPUB did not create its own coordinates")

-- Diagnostics must leave cached matching and its network-free reopen intact.
local stages = {}
local function perf(stage)
    stages[#stages + 1] = stage
    return 0
end
assert(finish(new("timed", { chapters[1] }, { offline = true, perf = perf })))
assert(#calls == count and store:get("book", "projection", "timed:1").stats.located == 2,
    "opening diagnostics changed matching results or initiated network work")
assert(table.concat(stages, ",") == "chapter_cache_begin,chapter_source_cache,chapter_projection_cache,chapter_match_begin,chapter_match,chapter_save",
    "opening diagnostics omit a cache, matching or persistence boundary")
stages = {}
assert(finish(new("timed", { chapters[1] }, { offline = true, perf = perf })))
assert(#calls == count and table.concat(stages, ",") == "chapter_cache_begin,chapter_cached",
    "cached reopen diagnostics caused unnecessary matching")

-- Reprojection, including an old checkpoint carrying embedded popup items,
-- must retain the shared source/thought rows and save positions only.
local json = require("json")
local Annotations = require("weread.lib.annotations")
local build_items, builds = Annotations.buildThoughtPopupItems, 0
Annotations.buildThoughtPopupItems = function(review)
    builds = builds + 1
    return build_items(review)
end
local source_before = json.encode(store:get("book", "source", "1"))
local thoughts_before = json.encode(store:list("book", "thought"))
local expected = store:get("book", "projection", "timed:1")
local saved_record = json.decode(json.encode(expected.records[1]))
saved_record.items = { { content = "old checkpoint thought" } }
store:put("book", "matching", "lean-resume:1", {
    records = { saved_record }, stats = { total = 2, located = 1, unmatched = 0, missing_text = 0, partial = 0 },
    next_index = 2, cursor_xp = saved_record.pos0,
    revision = expected.revision, matcher_version = expected.matcher_version, range_key = expected.range_key,
}, "1")
local write = store.write
local checkpoints = 0
store.write = function(self, book_id, changes)
    for _, change in ipairs(changes) do
        assert(change.kind == "matching" or change.kind == "projection" or change.kind == "status",
            "reprojection rewrote unchanged shared data: " .. change.kind)
        for _, record in ipairs(change.value and change.value.records or {}) do
            assert(record.items == nil, "checkpoint retained embedded thoughts")
        end
        if change.kind == "matching" and change.value then checkpoints = checkpoints + 1 end
    end
    return write(self, book_id, changes)
end
for _, key in ipairs({ "lean", "lean-resume" }) do
    assert(finish(new(key, { chapters[1] }, { store = store, offline = true })))
    assert(json.encode(store:get("book", "projection", key .. ":1")) == json.encode(expected),
        "lean matching changed positions or statistics")
end
store.write = nil
Annotations.buildThoughtPopupItems = build_items
assert(checkpoints == 2 and builds == 0 and #calls == count,
    "cached matching rebuilt thoughts, skipped checkpoints or used the network")
assert(json.encode(store:get("book", "source", "1")) == source_before
    and json.encode(store:list("book", "thought")) == thoughts_before,
    "cached matching changed shared source or popup data")

-- Legacy completed downloads may contain a large inline thought payload. An
-- ordinary open must preserve it rather than decode, clear, or replace it.
helper.legacy_checkpoints["/legacy.epub"] = {
    book_id = "book", started_at = 123, chapters = {
        { chapter_uid = "7", complete = true, underlines = { { range = "1-2", markText = "alpha" } },
            reviews = { { range = "1-2", pageReviews = {
                { review = { content = "legacy thought", author = {} } },
            } } } },
    },
}
store:importLegacy("book", "/legacy.epub", "legacy-document")
assert(not store:get("book", "thought", "7:1-2"))
assert(finish(new("legacy-document", { { chapterUid = "7" } }, { offline = true })))
assert(not store:get("book", "thought", "7:1-2")
    and store:get("book", "source", "7").reviews[1] and #calls == count,
    "ordinary legacy handling decoded or replaced the old thought payload")

-- Matcher upgrades must invalidate only the document projection. Downloaded
-- chapter data remains reusable and is projected again without network work.
local stale = store:get("book", "projection", "full:1")
stale.matcher_version = nil
store:put("book", "projection", "full:1", stale, "1")
local stale_status = store:get("book", "status", "full:1")
stale_status.matcher_version = nil
store:put("book", "status", "full:1", stale_status, "1")
count = #calls
assert(finish(new("full", { chapters[1] }, { offline = true })))
assert(#calls == count, "matcher upgrade re-downloaded cached annotation data")
assert(store:get("book", "projection", "full:1").matcher_version
    == External.MATCHER_VERSION, "matcher upgrade reused a stale projection")

assert(finish(new("other-selection", { { chapterUid = "2" } })))
assert(#calls == count and not store:get("book", "projection", "other-selection:1"), "selection processed absent chapters")
-- An interrupted refresh keeps the last committed results, and can resume.
fail_batch = true
assert(not finish(new("single", { chapters[1] }, { refresh = true })))
assert(store:get("book", "projection", "single:1").stats.located == 2)
fail_batch = false
count = #calls
assert(finish(new("single", { chapters[1] })))
assert(calls[count + 1] == "r1:3-4", "refresh restart ignored saved batches")
-- Empty success deletes old chapter results/thoughts, not other chapters.
empty = true
assert(finish(new("single", { chapters[1] }, { refresh = true })))
assert(#store:get("book", "projection", "single:1").records == 0)
assert(not store:get("book", "thought", "1:1-2"))
assert(store:get("book", "projection", "single:2").stats.located == 2)
-- A prefetch has no live document; opening it offline projects shared data.
empty = false
local prefetch = new(nil, { { chapterUid = "3" } })
prefetch.document = nil
assert(finish(prefetch))
count = #calls
assert(finish(new("chapter3", { { chapterUid = "3" } }, { offline = true })))
assert(#calls == count)
-- Cached but not yet projected chapters can finish offline. Stop exactly when
-- the next chapter needs downloading; never skip it or erase earlier results.
count = #calls
local offline = new("offline-resume", { { chapterUid = "3" }, { chapterUid = "4" } }, { offline = true })
local done, reason = finish(offline)
assert(done == nil and reason == Sync.NETWORK_REQUIRED and offline.index == 2)
assert(store:get("book", "projection", "offline-resume:3") and #calls == count)
assert(not store:get("book", "source", "4"))

-- A transient link-state false negative during the scheduled delay must not
-- interrupt a request that can still reach the WeRead endpoint.
local interrupted = new("disconnect", { { chapterUid = "8" } }, {
    is_online = function() return false end,
})
local running, state = interrupted:step()
assert(running == false and state.stage == "underlines")
done = finish(interrupted)
assert(done and #calls > count,
    "transient link state interrupted a successful annotation request")

-- A saved partial thoughts batch still needs the network; its checkpoint stays.
local partial = new("partial-offline", { { chapterUid = "4" } })
for _ = 1, 100 do
    assert(partial:step() ~= nil)
    if store:get("book", "batch", "4:1") then break end
end
assert(store:get("book", "batch", "4:1")); partial.cancelled = true
count = #calls
done, reason = finish(new("partial-offline", { { chapterUid = "4" } }, { offline = true }))
assert(done == nil and reason == Sync.NETWORK_REQUIRED and #calls == count)
assert(store:get("book", "download", "4").next_batch == 2)
assert(finish(new("partial-offline", { { chapterUid = "4" } })))
assert(calls[count + 1] == "r4:3-4", "reconnect must resume at the unfinished batch")

-- All thought batches may already be on disk while matching has not started.
-- Offline resume must consume them, not insist on a committed source snapshot.
store:put("book", "download", "5", { revision = "1", next_batch = 2,
    underlines = { { range = "1-2", markText = "alpha" } } }, "5")
store:put("book", "batch", "5:1", {}, "5")
count = #calls
assert(finish(new("batches-only", { { chapterUid = "5" } }, { offline = true })))
assert(#calls == count and store:get("book", "projection", "batches-only:5").stats.located == 1)

-- Missing original quote text is also a download boundary. Do not silently
-- commit an unmatched chapter simply because offline mode skipped that fetch.
store:put("book", "download", "6", { revision = "1", next_batch = 2,
    underlines = { { range = "1-2" } } }, "6")
store:put("book", "batch", "6:1", {}, "6")
done, reason = finish(new("missing-original", { { chapterUid = "6" } }, {
    offline = true, fetch_source = function() error("offline source fetch must not run") end,
}))
assert(done == nil and reason == Sync.NETWORK_REQUIRED and #calls == count)
assert(not store:get("book", "projection", "missing-original:6") and store:get("book", "download", "6"))
-- Explicit picker refetch discards old selected data first; generic refresh
-- above remains transactional. Offline refusal must happen before deletion.
assert(finish(new("selected-refresh", chapters)))
local untouched = json.encode(store:get("book", "source", "2"))
local old_revision = store:get("book", "source_status", "1").revision
count = #calls
done, reason = finish(new("selected-refresh", { chapters[1] }, { clear_existing = true, offline = true }))
assert(done == nil and reason == Sync.NETWORK_REQUIRED and #calls == count)
assert(store:get("book", "source_status", "1").revision == old_revision)
fail_batch = true
local reset = false
done = finish(new("selected-refresh", { chapters[1] }, { clear_existing = true, refresh = true,
    on_reset = function()
        reset = true
        assert(not store:get("book", "source", "1") and not store:get("book", "projection", "selected-refresh:1"))
    end,
}))
assert(done == nil and reset and calls[count + 1] == "u1")
assert(not store:get("book", "status", "selected-refresh:1")
    and not store:get("book", "thought", "1:1-2"), "failed refetch retained old selected results")
assert(json.encode(store:get("book", "source", "2")) == untouched)
fail_batch = false
assert(finish(new("selected-refresh", { chapters[1] })), "failed selected refetch could not resume")
assert(tonumber(store:get("book", "source_status", "1").revision) > tonumber(old_revision))
empty = true
assert(finish(new("selected-refresh", { chapters[1] }, { clear_existing = true, refresh = true })))
assert(store:get("book", "status", "selected-refresh:1").stats.total == 0,
    "successful zero-thought chapter must be recorded as retrieved")

-- A large single gateway batch is normalized in bounded chunks. Interrupting
-- after the first chunk leaves both the raw batch and its local checkpoint,
-- then resuming finishes without repeating either network request.
local bulk_calls = 0
local bulk_client = {
    get_chapter_underlines = function()
        bulk_calls = bulk_calls + 1
        local underlines = {}
        for i = 1, 101 do
            underlines[i] = { range = tostring(i) .. "-" .. tostring(i), markText = "bulk" }
        end
        return true, { underlines = underlines }
    end,
    build_chapter_review_batches = function(_self, ranges)
        return { ranges }
    end,
    get_chapter_reviews_batch = function(_self, _book, _uid, batch)
        bulk_calls = bulk_calls + 1
        local reviews = {}
        for _, range in ipairs(batch) do
            local page_reviews = {}
            for i = 1, 20 do
                page_reviews[i] = { review = { content = "bulk thought", author = {} } }
            end
            reviews[#reviews + 1] = { range = range, pageReviews = page_reviews }
        end
        return true, { reviews = reviews }
    end,
}
local bulk_store = helper.new()
local bulk_batch_reads = 0
local bulk_get = bulk_store.get
bulk_store.get = function(self, book_id, kind, key)
    if kind == "batch" and key == "bulk:1" then bulk_batch_reads = bulk_batch_reads + 1 end
    return bulk_get(self, book_id, kind, key)
end
local function bulk_job()
    return Sync:new({ store = bulk_store, client = bulk_client, book_id = "bulk",
        chapters = { { chapterUid = "bulk" } } })
end
local bulk = bulk_job()
for _ = 1, 20 do
    assert(bulk:step() ~= nil)
    local stage = bulk_store:get("bulk", "download", "bulk")
    if stage and stage.next_persist_review == 101 then break end
end
local bulk_stage = bulk_store:get("bulk", "download", "bulk")
assert(bulk_stage and bulk_stage.next_persist_batch == 1 and bulk_stage.next_persist_review == 101,
    "large thought batch was not checkpointed after 100 ranges")
assert(bulk_batch_reads == 1,
    "a segmented batch was decoded more than once in one coroutine run")
assert(bulk_store:get("bulk", "batch", "bulk:1") and bulk_store:get("bulk", "thought", "bulk:100-100"),
    "checkpoint lost staged reviews or normalized thoughts")
bulk.cancelled = true
bulk_batch_reads = 0
assert(finish(bulk_job()) and bulk_calls == 2,
    "resume repeated a saved large annotation batch")
assert(bulk_batch_reads == 1,
    "resumed persistence decoded its remaining batch more than once")
local bulk_source = bulk_store:get("bulk", "source", "bulk")
assert(bulk_source and #(bulk_source.reviews or {}) == 0
    and bulk_store:get("bulk", "thought", "bulk:101-101")
    and not bulk_store:get("bulk", "batch", "bulk:1"),
    "large annotation source retained raw reviews after persistence")

-- A completed cache from before per-range persistence is preserved during
-- ordinary/automatic runs. Only an explicit user sync replaces it without
-- decoding the potentially oversized source payload.
local legacy_store = helper.new()
legacy_store:put("book", "source", "legacy", {
    book_id = "book", chapter_uid = "legacy", underlines = { { range = "1-2" } },
    reviews = { { range = "1-2", pageReviews = { { review = { content = "old" } } } } },
}, "legacy")
legacy_store:put("book", "source_status", "legacy", { revision = "old", total = 1 }, "legacy")
local legacy_job = Sync:new({ store = legacy_store, client = client, book_id = "book",
    chapters = { { chapterUid = "legacy" } }, offline = true })
done, reason = finish(legacy_job)
assert(done and reason == nil
    and legacy_store:get("book", "source", "legacy").reviews[1],
    "automatic legacy handling erased the old source")
count = #calls
assert(finish(Sync:new({ store = legacy_store, client = client, book_id = "book",
    chapters = { { chapterUid = "legacy" } }, reset_legacy = true })))
local migrated_status = legacy_store:get("book", "source_status", "legacy")
assert(calls[count + 1] == "ulegacy" and migrated_status.persistence_version
        == Sync.PERSISTENCE_VERSION
    and #(legacy_store:get("book", "source", "legacy").reviews or {}) == 0,
    "legacy source was not replaced by bounded persistence")
helper.cleanup()
print("external_annotations_sync_spec: resume, cross-file reuse, empty updates and offline prefetch passed")
