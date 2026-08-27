package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = {}
local prevented, allowed = 0, 0
package.preload["device"] = function()
    return {
        isKindle = function() return false end,
        isCervantes = function() return false end,
        isKobo = function() return false end,
    }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end,
        setDirty = function() end,
        preventStandby = function() prevented = prevented + 1 end,
        allowStandby = function() allowed = allowed + 1 end,
    }
end

local catalog_chapters = {
    { chapterUid = 1, chapterIdx = 1, title = "Chapter One", wordCount = 100 },
    { chapterUid = 2, chapterIdx = 2, title = "Chapter Two", wordCount = 100 },
    { chapterUid = 3, chapterIdx = 3, title = "Chapter Three", wordCount = 100 },
}
local fetch_catalog_calls = 0
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        fetch_catalog = function()
            fetch_catalog_calls = fetch_catalog_calls + 1
            return catalog_chapters
        end,
    }
end
local located_chapters
local located_options
package.preload["weread.lib.external_annotations"] = function()
    return {
        locate = function(_document, chapters, options)
            located_chapters = chapters
            located_options = options
            for _, chapter in ipairs(chapters) do
                expect(chapter.underlines[1].markText == chapter.chapter_uid,
                    "raw underline payload was changed before final matching")
                local review = chapter.reviews[1].pageReviews[1].review
                expect(review.content == chapter.chapter_uid .. "-thought-1",
                    "raw thought payload was changed before final matching")
            end
            local records = {}
            for _, chapter in ipairs(chapters) do
                records[#records + 1] = {
                    pos0 = "xp0", pos1 = "xp1", chapter_uid = chapter.chapter_uid,
                }
            end
            return records, { located = #chapters, total = #chapters }
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end }
end
package.preload["weread.ui.xpointer_overlay"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["weread.lib.thoughts"] = function()
    return {
        collect_ranges = function(underlines)
            local ranges = {}
            for _, row in ipairs(underlines.underlines or {}) do
                ranges[#ranges + 1] = row.range
            end
            return ranges
        end,
    }
end

local dialogs = {}
package.preload["weread.ui.download_dialog"] = function()
    local Dialog = {}
    function Dialog:new(options)
        options.show = function() end
        options.close = function(current) current.closed = true end
        options.setTitle = function(current, title) current.title = title end
        options.reportProgress = function(current, value) current.progress = value end
        dialogs[#dialogs + 1] = options
        return options
    end
    return Dialog
end

local Crypto = require("weread.lib.crypto")
local SIGNATURE = Crypto.sha256_hex("book-1:1:2:3")

local document_value
local checkpoint
local function checkpoint_chapter(uid)
    for _, chapter in ipairs(checkpoint and checkpoint.chapters or {}) do
        if chapter.chapter_uid == tostring(uid) then return chapter end
    end
end

local function put_checkpoint_chapter(position, uid, value)
    value.position = position
    value.chapter_uid = tostring(uid)
    for index, chapter in ipairs(checkpoint.chapters) do
        if chapter.position == position or chapter.chapter_uid == tostring(uid) then
            checkpoint.chapters[index] = value
            return
        end
    end
    checkpoint.chapters[#checkpoint.chapters + 1] = value
end

local database = {
    getDocument = function() return document_value end,
    getSyncCheckpoint = function() return checkpoint end,
    replaceSyncCheckpoint = function(_self, _path, value)
        checkpoint = value
        checkpoint.chapters = {}
        return true
    end,
    saveSyncChapter = function(_self, _path, position, uid, value)
        value.review_batches = value.review_batches or {}
        put_checkpoint_chapter(position, uid, value)
        return true
    end,
    saveSyncReviewBatch = function(_self, _path, uid, batch_index, reviews)
        local chapter = checkpoint_chapter(uid)
        chapter.review_batches = chapter.review_batches or {}
        chapter.review_batches[batch_index] = {
            batch_index = batch_index,
            reviews = reviews,
        }
        return true
    end,
    finishSyncChapter = function(_self, _path, position, uid, value)
        value.review_batches = {}
        put_checkpoint_chapter(position, uid, value)
        return true
    end,
    saveDocument = function(_self, _path, value)
        document_value = value
        return true
    end,
    clearSyncCheckpoint = function()
        checkpoint = nil
        return true
    end,
}

local underline_calls = {}
local review_calls = {}
local client = {
    get_chapter_underlines = function(_self, _book_id, uid)
        underline_calls[#underline_calls + 1] = uid
        return true, { underlines = {
            { range = tostring(uid) .. "-range", markText = tostring(uid) },
        } }
    end,
    build_chapter_review_batches = function()
        return { { batch_index = 1 }, { batch_index = 2 } }
    end,
    get_chapter_reviews_batch = function(_self, _book_id, uid, batch)
        review_calls[#review_calls + 1] = {
            uid = uid,
            batch_index = batch.batch_index,
        }
        return true, { reviews = { { range = tostring(uid) .. "-range", pageReviews = {
            { review = { abstract = tostring(uid),
                content = tostring(uid) .. "-thought-"
                    .. tostring(batch.batch_index) } },
        } } } }
    end,
}

local info
local list_captured
local overlay_records
local host = {
    ui = { document = {
        file = "/books/local.epub",
        getCurrentPage = function() return 2 end,
        getPageCount = function() return 3 end,
        getToc = function()
            return {
                { title = "第一章 Chapter One" },
                { title = "第二章 Chapter Two" },
                { title = "第三章 Chapter Three" },
            }
        end,
    } },
    settings = {},
    client = client,
    external_annotations_db = database,
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback(); return true end,
    showInfo = function(_self, text) info = text end,
    showTransientInfo = function() end,
    showList = function(_self, title, items, empty_text)
        list_captured = { title = title, items = items, empty_text = empty_text }
    end,
}
local Controller = require("weread.ui.xpointer_overlay_controller")
for name, method in pairs(Controller) do host[name] = method end

local function run_one()
    local callback = table.remove(scheduled, 1)
    expect(callback ~= nil, "expected a scheduled sync step")
    callback()
end
local function run_all()
    while #scheduled > 0 do run_one() end
end

local function reset()
    scheduled = {}
    prevented, allowed = 0, 0
    fetch_catalog_calls = 0
    located_chapters = nil
    located_options = nil
    document_value = {
        binding = { book_id = "book-1", title = "Book", author = "Author" },
        records = {},
    }
    checkpoint = nil
    underline_calls = {}
    review_calls = {}
    info = nil
    list_captured = nil
    dialogs = {}
    overlay_records = nil
    host._xpointer_overlay = {
        setRecords = function(_self, records) overlay_records = records end,
    }
end

local function completed_chapter_payload(uid)
    return {
        position = tonumber(uid),
        chapter_uid = tostring(uid),
        complete = true,
        book_id = "book-1",
        underlines = { { range = tostring(uid) .. "-range", markText = tostring(uid) } },
        reviews = { { range = tostring(uid) .. "-range", pageReviews = {
            { review = { abstract = tostring(uid),
                content = tostring(uid) .. "-thought-1" } },
        } } },
    }
end

-- 1. A fresh single-chapter sync downloads only the selected chapter, reuses
--    the picker's catalog, and locates the result.
reset()
host:syncExternalAnnotationsChapter()
expect(list_captured ~= nil and #list_captured.items == 3,
    "chapter picker did not list the catalog")
expect(fetch_catalog_calls == 1,
    "chapter picker fetched the catalog more than once")
expect(list_captured.items[1].text == "第一章 Chapter One"
        and list_captured.items[3].text == "第三章 Chapter Three",
    "chapter picker did not show chapter numbers and titles")
expect(list_captured.items.current == 2,
    "chapter picker did not open near the current reading position")
expect(list_captured.items[1].post_text == nil,
    "uncompleted chapter was marked as synced")

list_captured.items[2].callback()
run_all()
expect(#underline_calls == 1 and underline_calls[1] == 2,
    "single-chapter sync downloaded another chapter")
expect(#review_calls == 2 and review_calls[1].uid == 2
        and review_calls[1].batch_index == 1
        and review_calls[2].batch_index == 2,
    "thought download did not target the selected chapter")
expect(fetch_catalog_calls == 1,
    "sync re-fetched the catalog despite a source catalog")
expect(located_chapters and #located_chapters == 1
        and located_chapters[1].chapter_uid == "2",
    "final matching did not limit itself to the selected chapter")
expect(checkpoint and checkpoint_chapter(2)
        and checkpoint_chapter(2).complete == true,
    "successful single-chapter sync discarded its completed state")
expect(document_value.records and #document_value.records == 1,
    "successful single-chapter sync did not save projected records")
expect(overlay_records and #overlay_records == 1,
    "single-chapter sync did not refresh the live overlay")
expect(info and info:find("Sync completed", 1, true),
    "successful single-chapter sync did not report completion")
expect(prevented == 1 and allowed == 1,
    "single-chapter sync did not balance its standby guard")

host:syncExternalAnnotationsChapter()
expect(list_captured.items[2].post_text == "Synced",
    "freshly synced chapter was not marked when the picker reopened")
list_captured.items[2].callback()
run_all()
expect(#underline_calls == 1 and #review_calls == 2,
    "re-selecting a freshly synced chapter repeated network requests")

-- 2. The picker marks checkpointed chapters as synced, and a single-chapter
--    sync keeps them in the final matching without re-downloading them.
reset()
checkpoint = {
    book_id = "book-1",
    format_version = 6,
    catalog_signature = SIGNATURE,
    total = 3,
    started_at = os.time(),
    chapters = { completed_chapter_payload(1) },
}
host:syncExternalAnnotationsChapter()
expect(list_captured.items[1].post_text == "Synced",
    "completed chapter was not marked as synced")
expect(list_captured.items[2].post_text == nil,
    "uncompleted chapter was marked as synced")

list_captured.items[3].callback()
run_all()
expect(#underline_calls == 1 and underline_calls[1] == 3,
    "single-chapter sync re-downloaded a checkpointed chapter")
expect(fetch_catalog_calls == 1,
    "resumed single-chapter sync re-fetched the catalog")
expect(located_chapters and #located_chapters == 2,
    "final matching did not include the checkpointed chapter")
expect(document_value.records and #document_value.records == 2,
    "resumed single-chapter sync dropped the checkpointed chapter records")
expect(overlay_records and #overlay_records == 2,
    "live overlay did not retain checkpointed chapter records")

-- 3. Re-picking an already completed chapter performs no network requests and
--    just re-locates its checkpointed data.
reset()
checkpoint = {
    book_id = "book-1",
    format_version = 6,
    catalog_signature = SIGNATURE,
    total = 3,
    started_at = os.time(),
    chapters = { completed_chapter_payload(1) },
}
host:syncExternalAnnotationsChapter()
list_captured.items[1].callback()
run_all()
expect(#underline_calls == 0 and #review_calls == 0,
    "completed chapter was re-downloaded")
expect(located_chapters and #located_chapters == 1
        and located_chapters[1].chapter_uid == "1",
    "re-sync of a completed chapter did not locate its data")
expect(checkpoint ~= nil and document_value.records
        and #document_value.records == 1,
    "re-sync of a completed chapter did not save projected records")
expect(prevented == 1 and allowed == 1,
    "no-network re-sync did not balance its standby guard")

-- 4. A single-chapter sync after a completed full sync (records present, no
--    checkpoint) keeps the other chapters' projected records.
reset()
document_value.records = {
    { pos0 = "x0", pos1 = "x1", chapter_uid = "1" },
    { pos0 = "x0", pos1 = "x1", chapter_uid = "2" },
}
host:syncExternalAnnotationsChapter()
list_captured.items[3].callback()
run_all()
expect(#underline_calls == 1 and underline_calls[1] == 3,
    "post-full-sync single-chapter sync downloaded another chapter")
expect(located_chapters and #located_chapters == 1
        and located_chapters[1].chapter_uid == "3",
    "post-full-sync single-chapter sync did not limit its download")
expect(document_value.records and #document_value.records == 3,
    "single-chapter sync dropped previously synced chapter records")

-- 5. Local TOC titles win over WeRead's whole-book chapterIdx. This mirrors
--    volume two of Lord of Mysteries, where chapterIdx 239 is chapter 24.
catalog_chapters[1] = {
    chapterUid = 239, chapterIdx = 239, title = "序列2", wordCount = 100,
}
catalog_chapters[2] = nil
catalog_chapters[3] = nil
local toc_volume_two = {
    { title = "第二部 无面人", xpointer = "/body/DocFragment[1]/p[1]" },
    { title = "第二十三章 会内委托", xpointer = "/body/DocFragment[2]/p[1]" },
    { title = "第二十四章 序列2", xpointer = "/body/DocFragment[3]/p[1]" },
    { title = "第二十五章 空想之龙", xpointer = "/body/DocFragment[4]/p[1]" },
}
host.ui.document.getToc = function()
    return toc_volume_two
end
host:syncExternalAnnotationsChapter()
expect(list_captured.items[1].text == "第二十四章 序列2",
    "chapter picker used whole-book chapterIdx instead of the local TOC title")
list_captured.items[1].callback()
run_all()
local range_239 = located_options and located_options.chapter_ranges
    and located_options.chapter_ranges["239"] or nil
expect(range_239 ~= nil
        and range_239.start_xpointer == "/body/DocFragment[3]/p[1]"
        and range_239.end_xpointer == "/body/DocFragment[4]/p[1]",
    "single-chapter sync did not bound the selected chapter by its local TOC XPointers")
expect(located_options.chapter_titles["239"] == "序列2"
        and located_options.chapter_local_titles["239"] == "第二十四章 序列2",
    "perf titles did not carry the WeRead and local TOC chapter names")

-- 6. WeRead per-update metadata suffixes like （第一更求推荐票）are stripped so
--    those chapters still match their local TOC entry and stay chapter-bounded.
reset()
catalog_chapters[1] = {
    chapterUid = 7, chapterIdx = 7, title = "梅丽莎（第一更求推荐票）", wordCount = 100,
}
catalog_chapters[2] = nil
catalog_chapters[3] = nil
host.ui.document.getToc = function()
    return {
        { title = "第一章 绯红", xpointer = "/d/1" },
        { title = "第二章 情况", xpointer = "/d/2" },
        { title = "第三章 梅丽莎", xpointer = "/d/3" },
        { title = "第四章 占卜", xpointer = "/d/4" },
    }
end
host:syncExternalAnnotationsChapter()
expect(list_captured.items[1].text == "第三章 梅丽莎",
    "update-suffix chapter title did not match its local TOC entry")
list_captured.items[1].callback()
run_all()
local range_suffixed = located_options and located_options.chapter_ranges
    and located_options.chapter_ranges["7"] or nil
expect(range_suffixed ~= nil and range_suffixed.start_xpointer == "/d/3"
        and range_suffixed.end_xpointer == "/d/4",
    "suffixed chapter was not bounded by its local TOC XPointers")

-- 7. A single-chapter pick does not re-locate checkpointed chapters whose
--    records were already saved; only the picked chapter is matched again.
reset()
catalog_chapters[1] = {
    chapterUid = 1, chapterIdx = 1, title = "Chapter One", wordCount = 100,
}
catalog_chapters[2] = {
    chapterUid = 2, chapterIdx = 2, title = "Chapter Two", wordCount = 100,
}
catalog_chapters[3] = {
    chapterUid = 3, chapterIdx = 3, title = "Chapter Three", wordCount = 100,
}
host.ui.document.getToc = function()
    return {
        { title = "第一章 Chapter One" },
        { title = "第二章 Chapter Two" },
        { title = "第三章 Chapter Three" },
    }
end
checkpoint = {
    book_id = "book-1",
    format_version = 6,
    catalog_signature = SIGNATURE,
    total = 3,
    started_at = os.time(),
    chapters = { completed_chapter_payload(1) },
}
document_value.records = {
    { pos0 = "x0", pos1 = "x1", chapter_uid = "1" },
}
host:syncExternalAnnotationsChapter()
list_captured.items[3].callback()
run_all()
expect(#underline_calls == 1 and underline_calls[1] == 3,
    "single-chapter sync downloaded the wrong chapter")
expect(located_chapters and #located_chapters == 1
        and located_chapters[1].chapter_uid == "3",
    "single-chapter sync re-located a checkpointed chapter that already has records")
expect(document_value.records and #document_value.records == 2,
    "single-chapter sync dropped the saved records of another chapter")

print(("external_annotations_single_chapter_spec: %d checks"):format(checks))
