package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.annotations"] = function()
    return {
        buildThoughtPopupItems = function(review)
            return { { content = review.pageReviews[1].review.content } }
        end,
    }
end

local External = require("weread.lib.external_annotations")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local rows = External.normalize_search({ results = {
    { books = { { bookInfo = { bookId = 7, title = "本地书", author = "作者" } } } },
} })
expect(#rows == 1 and rows[1].book_id == "7" and rows[1].title == "本地书",
    "grouped WeRead search results were not normalized")

-- Ordered XPointer space used by the compareXPointers mock.  Chapter texts
-- are CJK-only (3 bytes per character), which also exercises byte-offset
-- mapping through the visible-character walk.
local order = {
    ch1s = 1, ch2s = 13, ch3s = 16, xp3 = 17, w9 = 5,
}
local chapter1_text = "甲重复原文乙重复原文丙"
local chapter2_text = "来自想法摘要"
local find_all_calls = 0
local find_text_calls = 0
local chapter_search_max_hits
local get_text_calls = 0
local walk_steps = 0
local goto_calls = 0
local current_xpointer = "reading-position"
local document = {
    findAllText = function()
        find_all_calls = find_all_calls + 1
        return {}
    end,
    findText = function(_self, quote, _origin, _direction, _case_insensitive,
            _page, _regex, max_hits)
        find_text_calls = find_text_calls + 1
        chapter_search_max_hits = max_hits
        if quote == "尾部章节原文" then
            return { { start = "xp3", ["end"] = "xp3e" } }
        end
        return {}
    end,
    getTextFromXPointers = function(_self, start_xp)
        get_text_calls = get_text_calls + 1
        if start_xp == "ch1s" then return chapter1_text end
        if start_xp == "ch2s" then return chapter2_text end
        return ""
    end,
    getNextVisibleChar = function()
        walk_steps = walk_steps + 1
        return "w" .. walk_steps
    end,
    compareXPointers = function(_self, a, b)
        local oa, ob = order[a], order[b]
        if not oa or not ob then return 0 end
        if ob > oa then return 1 elseif ob < oa then return -1 end
        return 0
    end,
    getXPointer = function() return current_xpointer end,
    gotoXPointer = function(_self, xpointer)
        current_xpointer = xpointer
        goto_calls = goto_calls + 1
    end,
    getPosFromXPointer = function(_self, xp) return order[xp] end,
}

local records, stats = External.locate(document, {
    {
        book_id = "7", chapter_uid = "1",
        underlines = { { range = "2-3", markText = "重复原文" },
            { range = "4-5", markText = "重复原文" } },
        reviews = {},
    },
    {
        book_id = "7", chapter_uid = "2",
        underlines = { { range = "8-9" }, { range = "10-11", markText = "不存在的原文" } },
        reviews = { { range = "8-9", pageReviews = {
            { review = { abstract = "来自想法摘要", content = "想法" } },
        } } },
    },
    {
        book_id = "7", chapter_uid = "3",
        underlines = { { range = "12-13", markText = "尾部章节原文" } },
        reviews = {},
    },
}, { chapter_ranges = {
    ["1"] = { start_xpointer = "ch1s", end_xpointer = "ch2s" },
    ["2"] = { start_xpointer = "ch2s", end_xpointer = "ch3s" },
    ["3"] = { start_xpointer = "ch3s" },
}, chapter_titles = {
    ["1"] = "第一章", ["2"] = "第二章", ["3"] = "第三章",
}, chapter_local_titles = {
    ["1"] = "第一章 本地", ["2"] = "第二章 本地", ["3"] = "第三章 本地",
} })

-- Chapter 1: both repeated quotations resolved in document order through the
-- chapter text index (no CREngine search at all).
expect(#records == 4 and records[1].pos0 == "w2" and records[1].pos1 == "w6",
    "first repeated quotation was not located inside the chapter bounds")
expect(records[2].pos0 == "w7" and records[2].pos1 == "w11",
    "second repeated quotation was not located after the first")
expect(records[1].book_id == "7" and records[1].chapter_uid == "1"
        and records[1].range == "2-3",
    "located record lost its identity fields")
-- Chapter 2: review-abstract fallback quote located in the chapter text.
expect(records[3].pos0 == "w12" and records[3].pos1 == "ch3s"
        and records[3].items[1].content == "想法",
    "review abstract fallback was not preserved or bounded by the chapter end")
-- Chapter 3 (no end bound): chapter-start findText with a single hit.
expect(records[4].pos0 == "xp3" and records[4].pos1 == "xp3e",
    "unbounded chapter did not fall back to chapter-start findText")
expect(stats.total == 5 and stats.located == 4 and stats.unmatched == 1,
    "locator statistics are incorrect")
expect(find_all_calls == 1,
    "chapter-bounded matching scanned the whole book per quote")
expect(find_text_calls == 1 and chapter_search_max_hits == 1,
    "chapter findText fallback did not stop after its first forward match")
expect(get_text_calls == 2,
    "chapter text was extracted more than once per bounded chapter")
expect(walk_steps == 12,
    "visible-character walk did not stop at the furthest needed offset")
expect(goto_calls == 2 and current_xpointer == "reading-position",
    "matching moved the reading position: " .. tostring(current_xpointer))

-- A chapter whose walk diverges from the extracted text must fall back to
-- whole-book search instead of producing mislocated records.
local diverged_walk_calls = 0
local diverged = {
    findAllText = function()
        find_all_calls = find_all_calls + 1
        return { { start = "w9", ["end"] = "w9e" } }
    end,
    getTextFromXPointers = function() return "甲乙丙" end,
    getNextVisibleChar = function()
        diverged_walk_calls = diverged_walk_calls + 1
        return nil -- the walk cannot produce any XPointer
    end,
    compareXPointers = function(_self, a, b)
        local oa, ob = order[a], order[b]
        if not oa or not ob then return 0 end
        if ob > oa then return 1 elseif ob < oa then return -1 end
        return 0
    end,
}
local diverged_records, diverged_stats = External.locate(diverged, {
    { book_id = "7", chapter_uid = "1",
        underlines = { { range = "2-3", markText = "甲乙丙" } }, reviews = {} },
}, { chapter_ranges = {
    ["1"] = { start_xpointer = "ch1s", end_xpointer = "ch2s" },
} })
expect(#diverged_records == 1 and diverged_records[1].pos0 == "w9",
    "diverged walk did not fall back to whole-book search")
expect(diverged_stats.located == 1,
    "diverged walk fallback reported wrong statistics")

print(("external_annotations_spec: %d checks"):format(checks))
