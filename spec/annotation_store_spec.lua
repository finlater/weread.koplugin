package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local store = helper.new()
local attrs = { size = 1234, modification = 5678, change = 100 }
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return attrs end }
end
package.preload["version"] = function()
    return { getCurrentRevision = function() return "test-revision" end }
end
local stable_key = store.documentKey("/books/test.epub")
attrs.change = 200
assert(store.documentKey("/books/test.epub") == stable_key,
    "document key changed when only ctime changed")
attrs.modification = 5679
assert(store.documentKey("/books/test.epub") ~= stable_key,
    "document key did not change when the EPUB mtime changed")
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
-- Selective cleanup removes every annotation/projection for selected UIDs,
-- across editions, while retaining the book text, mappings and other chapters.
for _, kind in ipairs({ "source", "source_status", "download", "batch", "thought", "refresh",
    "projection", "matching", "status" }) do
    store:put("book", kind, "selected", { marker = kind }, "1")
    store:put("book", kind, "other-edition", { marker = kind }, "1")
    store:put("book", kind, "untouched", { marker = kind }, "2")
end
for _, kind in ipairs({ "meta", "chapter_mapping", "generation", "original", "migration" }) do
    store:put("book", kind, "keep", { preserved = true }, "1")
end
store:clearChapters("book", { { chapterUid = "1" } })
for _, kind in ipairs({ "source", "source_status", "download", "batch", "thought", "refresh",
    "projection", "matching", "status" }) do
    assert(not store:get("book", kind, "selected") and not store:get("book", kind, "other-edition"))
    assert(store:get("book", kind, "untouched").marker == kind)
end
for _, kind in ipairs({ "meta", "chapter_mapping", "generation", "original", "migration" }) do
    assert(store:get("book", kind, "keep").preserved)
end
-- Clearing underlines and thoughts must give the space back, not just leave
-- freed pages inside the database file (#205).
local function file_size(path)
    local handle = assert(io.open(path, "rb"))
    local size = handle:seek("end")
    handle:close()
    return size
end
local bulky = { text = string.rep("x", 4096) }
local bulk_changes = {}
for index = 1, 300 do
    bulk_changes[#bulk_changes + 1] = { kind = "thought", key = "bulk-" .. index, uid = "1", value = bulky }
end
store:write("vacuum-book", bulk_changes)
store:put("vacuum-book", "original", "1", { text = "kept" }, "1")
local vacuum_path = helper.paths["weread-book-vacuum-book"]
local before_clear = file_size(vacuum_path)
assert(before_clear > 1000000, "bulk fixture too small to measure compaction")
assert(store:clearKinds("vacuum-book", { "thought" }))
local after_clear = file_size(vacuum_path)
assert(after_clear * 10 < before_clear,
    "clearKinds left the database at " .. after_clear .. " bytes (was " .. before_clear .. ")")
assert(not store:get("vacuum-book", "thought", "bulk-1"), "cleared rows survived compaction")
assert(store:get("vacuum-book", "original", "1").text == "kept", "compaction dropped retained data")
assert(store:clearBook("book"), "book annotation database cleanup failed")
assert(not store:get("book", "source", "1"), "book annotation database survived cleanup")
helper.cleanup()
print("annotation_store_spec: real SQLite persistence, isolation, rollback and migration passed")
