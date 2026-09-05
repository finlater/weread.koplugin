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
print("annotation_locator_regressions_spec: overlap, equality, bounds, fast path and matching resume passed")
