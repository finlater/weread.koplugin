package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local captured = {}
package.preload["weread.lib.annotations"] = function()
    return {
        buildThoughtPopupItems = function(review)
            return { { content = review.pageReviews[1].review.content } }
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        info = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring(select(i, ...))
            end
            captured[#captured + 1] = table.concat(parts, " ")
        end,
        warn = function() end,
    }
end

local External = require("weread.lib.external_annotations")

-- flatten_text removes paragraph separators, ASCII spaces and common Unicode
-- spaces, and keeps every other character.
expect(External.flatten_text("甲乙丙") == "甲乙丙",
    "plain CJK text was altered by flattening")
expect(External.flatten_text("甲 乙\t丙") == "甲乙丙",
    "ASCII whitespace was not removed by flattening")
expect(External.flatten_text("甲\n乙\r\n丙") == "甲乙丙",
    "paragraph separators were not removed by flattening")
expect(External.flatten_text("甲\xE3\x80\x80乙") == "甲乙",
    "ideographic space was not removed by flattening")
expect(External.flatten_text("甲\xC2\xA0乙") == "甲乙",
    "no-break space was not removed by flattening")
expect(External.flatten_text("") == "" and External.flatten_text("   ") == "",
    "empty and whitespace-only texts were not flattened to empty")

-- find_in_flat returns start and exclusive-end byte offsets, and honours the
-- previous match end so repeated quotes resolve in order.
local flat = External.flatten_text("重复原文重复原文")
expect(flat == "重复原文重复原文", "flattened fixture was corrupted")
local s1, e1 = External.find_in_flat(flat, "重复原文", 0)
expect(s1 == 1 and e1 == 13, "first occurrence offsets are wrong: " .. tostring(s1))
local s2, e2 = External.find_in_flat(flat, "重复原文", e1)
expect(s2 == 13 and e2 == 25, "second occurrence offsets are wrong: " .. tostring(s2))
expect(External.find_in_flat(flat, "重复原文", e2) == nil,
    "exhausted quote matched again")
expect(External.find_in_flat("来自想法摘要", "来自 想法 摘要", 0) ~= nil,
    "whitespace inside a quote broke flat matching")
expect(External.find_in_flat("来自想法摘要", "不存在", 0) == nil,
    "absent quote was found in the chapter text")

-- advance_chapter_walk maps flat byte offsets to XPointers, consuming a walk
-- step for whitespace characters (which have no flat offset of their own) but
-- not for the '\n' paragraph separators inserted by getTextFromXPointers.
local steps = 0
local walk_document = {
    getNextVisibleChar = function()
        steps = steps + 1
        return "w" .. steps
    end,
}
local extracted = "甲 乙\n丙"
local walk = External.new_chapter_walk(walk_document, extracted, "ch1s")
expect(External.advance_chapter_walk(walk, 7) == true,
    "walk could not reach the last needed character")
expect(walk.xp_at[1] == "w1" and walk.xp_at[4] == "w3" and walk.xp_at[7] == "w4",
    "walk did not skip whitespace and separators in flat offset space")
expect(walk.xp_at[2] == nil and steps == 4,
    "walk visited the wrong number of visible characters")

-- A walk that cannot produce XPointers (document API divergence) is invalid
-- and forces the caller onto the whole-book fallback.
local dry = External.new_chapter_walk({
    getNextVisibleChar = function() return nil end,
}, extracted, "ch1s")
expect(External.advance_chapter_walk(dry, 1) == false and dry.valid == false,
    "diverged walk was not invalidated")

-- Locate end-to-end: chapter-bounded matching is fast (no CREngine search),
-- preserves the reading position, and every perf line carries the stable tag
-- without leaking the quotation text.
local order = { ch1s = 1, ch2s = 13 }
local find_all_calls = 0
local find_text_calls = 0
local moved = 0
local locate_steps = 0
local document = {
    findAllText = function()
        find_all_calls = find_all_calls + 1
        return {}
    end,
    findText = function()
        find_text_calls = find_text_calls + 1
        return {}
    end,
    getTextFromXPointers = function() return "甲敏感原文内容" end,
    getNextVisibleChar = function()
        locate_steps = locate_steps + 1
        return "w" .. locate_steps
    end,
    compareXPointers = function(_self, a, b)
        local oa, ob = order[a], order[b]
        if not oa or not ob then return 0 end
        if ob > oa then return 1 elseif ob < oa then return -1 end
        return 0
    end,
    getXPointer = function() return "user-page" end,
    gotoXPointer = function() moved = moved + 1 end,
}
local records, stats = External.locate(document, {
    { book_id = "7", chapter_uid = "42",
        underlines = { { range = "1-2", markText = "敏感原文内容" } },
        reviews = {} },
}, { chapter_ranges = {
    ["42"] = { start_xpointer = "ch1s", end_xpointer = "ch2s" },
}, chapter_titles = { ["42"] = "序列2" },
    chapter_local_titles = { ["42"] = "第二十四章 序列2" } })

expect(#records == 1 and records[1].pos0 == "w2" and records[1].pos1 == "ch2s",
    "chapter-bounded locate did not resolve the quote through the text index")
expect(stats.total == 1 and stats.located == 1 and stats.unmatched == 0,
    "chapter-bounded locate reported wrong statistics")
expect(find_all_calls == 0 and find_text_calls == 0,
    "chapter-bounded locate scanned the book with CREngine")
expect(moved == 0, "chapter-bounded locate moved the reading position")

local perf_lines = {}
local leaked = false
for _, line in ipairs(captured) do
    if line:find("external_annotation_perf", 1, true) then
        perf_lines[#perf_lines + 1] = line
    end
    if line:find("敏感原文内容", 1, true) then leaked = true end
end
expect(#perf_lines >= 3, "perf logging did not emit chapter and quote lines")
expect(not leaked, "perf logging leaked the full quotation text")
expect(perf_lines[1]:find("book_id=7", 1, true)
        and perf_lines[1]:find("chapter_uid=42", 1, true)
        and perf_lines[1]:find("we_title=\"序列2\"", 1, true)
        and perf_lines[1]:find("local_title=\"第二十四章 序列2\"", 1, true)
        and perf_lines[1]:find("start_xp=true", 1, true)
        and perf_lines[1]:find("end_xp=true", 1, true)
        and perf_lines[1]:find("indexed=true", 1, true),
    "chapter perf line is missing required fields")
expect(perf_lines[2]:find("seq=1", 1, true)
        and perf_lines[2]:find("len=18", 1, true)
        and perf_lines[2]:find("hash=", 1, true)
        and perf_lines[2]:find("mode=chapter_text", 1, true)
        and perf_lines[2]:find("hits=1", 1, true)
        and perf_lines[2]:find("found=true", 1, true),
    "quote perf line is missing required fields")
expect(perf_lines[3]:find("stage=chapter", 1, true)
        and perf_lines[3]:find("located=1", 1, true)
        and perf_lines[3]:find("chapter_ms=", 1, true),
    "chapter summary perf line is missing required fields")

print(("external_annotations_chapter_index_spec: %d checks"):format(checks))
