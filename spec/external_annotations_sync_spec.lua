-- Shared-book pipeline regressions, using the actual locator and SQLite store.
package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local Sync = require("weread.lib.annotation_sync")
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
helper.cleanup()
print("external_annotations_sync_spec: resume, cross-file reuse, empty updates and offline prefetch passed")
