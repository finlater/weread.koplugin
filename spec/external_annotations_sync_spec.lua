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
package.preload["weread.lib.content"] = function()
    return {
        ensure_reader_state = function() end,
        fetch_catalog = function()
            return {
                { chapterUid = 1 },
                { chapterUid = 2 },
                { chapterUid = 3 },
            }
        end,
    }
end
local located_chapters
local force_zero_matches = false
package.preload["weread.lib.external_annotations"] = function()
    return {
        locate = function(_document, chapters)
            located_chapters = chapters
            if force_zero_matches then
                return {}, { located = 0, total = #chapters,
                    missing_text = 0, unmatched = #chapters }
            end
            for _, chapter in ipairs(chapters) do
                expect(chapter.underlines[1].markText == chapter.chapter_uid,
                    "raw underline payload was changed before final matching")
                local review = chapter.reviews[1].pageReviews[1].review
                expect(review.content == chapter.chapter_uid .. "-thought-1",
                    "raw thought payload was changed before final matching")
            end
            local records = {}
            if chapters[1] then
                records[1] = {
                    pos0 = "xp0", pos1 = "xp1",
                    chapter_uid = chapters[1].chapter_uid,
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

local document_value = {
    binding = { book_id = "book-1", title = "Book", author = "Author" },
    records = {},
}
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
local remote_underlines_empty = false
local client = {
    get_chapter_underlines = function(_self, _book_id, uid)
        underline_calls[#underline_calls + 1] = uid
        if remote_underlines_empty then
            return true, { underlines = {} }
        end
        return true, { underlines = {
            { range = tostring(uid) .. "-range", markText = tostring(uid) },
        } }
    end,
    build_chapter_review_batches = function(_self, ranges)
        if #ranges == 0 then return {} end
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

local info, transient
local host = {
    ui = { document = { file = "/books/local.epub" } },
    settings = {},
    client = client,
    external_annotations_db = database,
    requireLogin = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback(); return true end,
    showInfo = function(_self, text) info = text end,
    showTransientInfo = function(_self, text) transient = text end,
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

host:syncExternalAnnotations()
expect(dialogs[1].description
        and dialogs[1].description:find("resumed automatically", 1, true),
    "sync dialog did not explain cancellation and automatic resume")
run_one() -- prepare catalog
run_one() -- download chapter 1 underlines
run_one() -- download and checkpoint only thought batch 1
dialogs[1].buttons[1][1].callback()
run_all()
expect(transient and transient:find("saved", 1, true),
    "cancelling did not explain that the checkpoint was retained")
expect(#underline_calls == 1 and underline_calls[1] == 1,
    "cancellation downloaded another chapter")
expect(#review_calls == 1 and review_calls[1].uid == 1
        and review_calls[1].batch_index == 1,
    "thought download stringified the chapterUid")
expect(checkpoint and #checkpoint.chapters == 1
        and checkpoint.chapters[1].complete == false
        and #checkpoint.chapters[1].review_batches == 1,
    "cancellation discarded the partial thought-batch checkpoint")
expect(dialogs[1].progress == 0.5,
    "thought batches did not advance fractional chapter progress")

host:syncExternalAnnotations()
run_all()
expect(#underline_calls == 3
        and underline_calls[2] == 2
        and underline_calls[3] == 3,
    "resume re-downloaded the partial chapter underlines")
expect(#review_calls == 6 and review_calls[2].uid == 1
        and review_calls[2].batch_index == 2,
    "resume did not continue at the next thought batch")
expect(located_chapters and #located_chapters == 3,
    "final matching did not include resumed and newly downloaded chapters")
expect(checkpoint == nil, "successful sync retained its temporary checkpoint")
expect(document_value.records and #document_value.records == 1,
    "successful sync did not save final projected records")
expect(info and info:find("Sync completed", 1, true),
    "successful resumed sync did not report completion")

local successful_document = document_value
force_zero_matches = true
host:syncExternalAnnotations()
run_all()
expect(document_value == successful_document
        and document_value.records and #document_value.records == 1,
    "zero-match sync overwrote the existing document")
expect(checkpoint and #checkpoint.chapters == 3,
    "zero-match sync cleared its resumable checkpoint")
expect(info and info:find("interrupted", 1, true),
    "zero-match sync was incorrectly reported as successful")

-- A fresh successful sync with no remote underlines must clear records from
-- the previous sync without sending empty chapters through the locator.
checkpoint = nil
force_zero_matches = false
remote_underlines_empty = true
host:syncExternalAnnotations()
run_all()
expect(located_chapters and #located_chapters == 0,
    "empty remote chapters were sent to the local locator")
expect(document_value.records and #document_value.records == 0,
    "empty remote sync retained stale local underline records")
expect(checkpoint == nil,
    "successful empty remote sync retained its temporary checkpoint")
expect(prevented == 4 and allowed == 4,
    "annotation sync did not balance its standby guards")

print(("external_annotations_sync_spec: %d checks"):format(checks))
