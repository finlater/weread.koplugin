package.path = "./?.lua;" .. package.path
local External = require("weread.lib.external_annotations")
local text, searches, positions, moves = "abcdef", 0, 0, 0
local function xp(value) return tonumber(value) end
local document = {
    getTextFromXPointers = function(_self, first, last) return text:sub(xp(first) + 1, xp(last)) end,
    getPrevVisibleChar = function(_self, point) return xp(point) > 0 and tostring(xp(point) - 1) or nil end,
    compareXPointers = function(_self, a, b)
        return xp(a) < xp(b) and 1 or xp(a) > xp(b) and -1 or 0
    end,
    getPosFromXPointer = function() positions = positions + 1; error("layout must not run") end,
    gotoXPointer = function() moves = moves + 1; error("reading position changed") end,
    findAllText = function(_self, quote)
        searches = searches + 1
        local found, init = {}, 1
        while true do
            local first, last = text:find(quote, init, true)
            if not first then break end
            found[#found + 1] = { start = tostring(first - 1), ["end"] = tostring(last) }
            init = first + 1
        end
        return found
    end,
}
local function locate(rows, options)
    options = options or {}
    options.chapter_ranges = options.chapter_ranges or { ["1"] = {
        start_xpointer = "0", end_xpointer = tostring(#text) } }
    return External.locate(document, { { book_id = "b", chapter_uid = "1", underlines = rows, reviews = {} } }, options)
end
local rows = {
    { range = "0-3", markText = "abc" }, { range = "2-5", markText = "cde" },
    { range = "3-6", markText = "def" },
}
local records, stats = locate(rows)
assert(#records == 3 and stats.located == 3, "overlapping or adjacent fast matches lost")
assert(searches == 0 and positions == 0 and moves == 0, "fast path used whole-book search, layout or navigation")

-- Generated footnote labels are visible in downloaded EPUBs but absent from
-- WeRead quotes. The fast path must ignore them while retaining the correct
-- document endpoints, and zero-width BOM characters must be removed from the
-- remote quotation.
text = "abc[36]def"
records = locate({ { range = "0-6", markText = "abc\239\187\191def" } })
assert(#records == 1 and records[1].pos0 == "0" and records[1].pos1 == "10",
    "generated footnote label broke quote matching or XPointer mapping")
assert(searches == 0, "footnote-normalized quote fell back to whole-book search")
text = "abcdef"

records = locate({ { range = "0-3", markText = "abc" }, { range = "0-6", markText = "abcdef" } })
assert(#records == 2 and records[1].pos0 == records[2].pos0, "equal-start underlines lost")
local previous = document.getPrevVisibleChar
document.getPrevVisibleChar = nil
records = locate(rows)
assert(#records == 3, "fallback rejected boundary, overlap or adjacency")
-- A hit spanning the following chapter must not be accepted.
records = locate({ { range = "0-6", markText = "abcdef" } }, {
    chapter_ranges = { ["1"] = { start_xpointer = "0", end_xpointer = "3" } } })
assert(#records == 0, "fallback accepted a range crossing the chapter end")
document.getPrevVisibleChar = previous
-- Resume from the last saved matching batch, not from the first underline.
local chunks, many = {}, {}
for i = 1, 40 do
    local quote = string.format("L%02d", i)
    chunks[#chunks + 1] = quote
    many[#many + 1] = { range = (i * 4) .. "-" .. (i * 4 + 3), markText = quote }
end
text = table.concat(chunks, " ")
local checkpoint
local worker = coroutine.create(function()
    return locate(many, { checkpoint = function(state) checkpoint = state end,
        yield = function() coroutine.yield() end })
end)
assert(coroutine.resume(worker))
assert(checkpoint and checkpoint.next_index == 17 and #checkpoint.records == 16)
records, stats = locate(many, { resume = checkpoint })
assert(#records == 40 and stats.located == 40 and stats.total == 40, "matching resume lost or duplicated records")

-- The reverse walk yields on a CPU-work budget (and at most every 256 steps)
-- so one long chapter cannot monopolise the UI, and each yield carries a
-- progress hint the dialog can display while the first quote is still walking.
do
    local long = string.rep("z", 2000)
    local walk_document = { getPrevVisibleChar = function(_self, point)
        local n = tonumber(point)
        return n > 0 and tostring(n - 1) or nil
    end }
    local clock_calls, hints = 0, {}
    local function advancing_clock() clock_calls = clock_calls + 1; return clock_calls * 0.02 end
    local walk = External.new_chapter_walk(walk_document, long, tostring(#long))
    walk.clock = advancing_clock
    walk.yield = function(hint) hints[#hints + 1] = hint end
    assert(External.advance_chapter_walk(walk, 1), "time-budgeted walk did not reach its target")
    assert(#hints > 0 and walk.steps == #long and walk.yields == #hints,
        "time-budgeted walk yield or step counters are incorrect")
    local previous_progress = -1
    for _, hint in ipairs(hints) do
        assert(type(hint) == "table" and hint.steps and hint.progress
            and hint.progress >= previous_progress and hint.progress <= 1,
            "walk yield did not carry a monotonic progress hint")
        previous_progress = hint.progress
    end
end
do
    local long = string.rep("y", 700)
    local walk_document = { getPrevVisibleChar = function(_self, point)
        local n = tonumber(point)
        return n > 0 and tostring(n - 1) or nil
    end }
    local walk = External.new_chapter_walk(walk_document, long, tostring(#long))
    walk.clock = function() return 0 end
    local step_marks = {}
    walk.yield = function(hint) step_marks[#step_marks + 1] = hint.steps end
    assert(External.advance_chapter_walk(walk, 1), "step-capped walk did not reach its target")
    assert(#step_marks >= 2, "step-capped walk did not yield")
    local previous_mark = 0
    for _, mark in ipairs(step_marks) do
        assert(mark - previous_mark <= 256, "walk went more than 256 steps without yielding")
        previous_mark = mark
    end
end

-- The whole-book fallback is the only unbounded non-yielding native path; the
-- sync caller bounds it per chapter. Capped quotes are recorded unmatched, and
-- the capped calls are still separated by a yield point.
do
    document.getPrevVisibleChar = nil
    text, searches = "nothing", 0
    local cap_rows = {}
    for i = 1, 10 do
        cap_rows[#cap_rows + 1] = { range = tostring(i) .. "-" .. tostring(i),
            markText = "capquote" .. i }
    end
    local fallback_yields = 0
    local _, stats2 = locate(cap_rows, { max_fallbacks = 4,
        fallback_yield = function() fallback_yields = fallback_yields + 1 end })
    assert(searches == 4, "fallback cap was not enforced: searches=" .. tostring(searches))
    assert(fallback_yields == 3, "fallback calls were not separated by a yield point")
    assert(stats2.total == 10 and stats2.located == 0 and stats2.unmatched == 10,
        "capped fallbacks were not recorded as unmatched")
    document.getPrevVisibleChar = previous
end
print("annotation_locator_regressions_spec: overlap, equality, bounds, fast path and matching resume passed")
