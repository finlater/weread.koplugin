package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local store = helper.new()
store:put("book", "source", "1", { revision = "a", underlines = {} }, "1")
assert(helper.new():get("book", "source", "1").revision == "a", "shared data must survive reopening")
assert(not store:get("other", "source", "1"), "books must not share annotation data")
local ok = pcall(function()
    store:write("book", {
        { kind = "source", key = "1", uid = "1", value = { revision = "bad" } },
        { kind = nil, key = "fail", value = true },
    })
end)
assert(not ok and store:get("book", "source", "1").revision == "a", "chapter transaction must roll back")
store:put("book", "download", "1", { next_batch = 2 }, "1")
store:put("book", "batch", "1:1", { "thought" }, "1")
store:commitChapter("book", "1", { revision = "b" }, "single", { records = { { pos0 = "single-xp" } } })
assert(not store:get("book", "download", "1") and not store:get("book", "batch", "1:1"))
assert(store:get("book", "projection", "single:1").records[1].pos0 == "single-xp")
assert(not store:get("book", "projection", "full:1"), "XPointers cannot leak between EPUBs")
assert(store:list("book", "source")["1"].revision == "b")
helper.legacy_entries["old.epub"] = { binding = { book_id = "book" }, records = {} }
helper.legacy_checkpoints["old.epub"] = { book_id = "book", started_at = 1, chapters = {
    { chapter_uid = "1", complete = true, underlines = { "stale" } },
    { chapter_uid = "2", complete = false, underlines = {}, review_batches = {
        { batch_index = 1, reviews = { "saved" } } } },
} }
store:importLegacy("book", "old.epub", "old-key")
assert(store:get("book", "source", "1").revision == "b", "migration overwrote newer shared source")
assert(store:get("book", "download", "2").next_batch == 2)
assert(store:get("book", "batch", "2:1")[1] == "saved")
assert(helper.legacy_checkpoints["old.epub"], "migration erased fallback data")
store:put("book", "source", "deleted", { revision = "old" }, "deleted")
store:put("book", "projection", "full:deleted", { records = {} }, "deleted")
store:pruneCatalog("book", { { chapterUid = "1" }, { chapterUid = "2" } })
assert(not store:get("book", "source", "deleted") and not store:get("book", "projection", "full:deleted"))
assert(store:get("book", "source", "1"), "catalog cleanup removed a live chapter")
helper.cleanup()
print("annotation_store_spec: real SQLite persistence, isolation, rollback and migration passed")
