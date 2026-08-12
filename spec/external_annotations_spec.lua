package.path = "./?.lua;" .. package.path

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

local positions = { xp1 = 10, xp2 = 20, xp3 = 30 }
local document = {
    findAllText = function(_self, quote)
        if quote == "重复原文" then
            return { { start = "xp1", ["end"] = "xp1e" }, { start = "xp2", ["end"] = "xp2e" } }
        elseif quote == "来自想法摘要" then
            return { { start = "xp3", ["end"] = "xp3e" } }
        end
    end,
    getPosFromXPointer = function(_self, xp) return positions[xp] end,
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
        underlines = { { range = "8-9" } },
        reviews = { { range = "8-9", pageReviews = {
            { review = { abstract = "来自想法摘要", content = "想法" } },
        } } },
    },
})
expect(#records == 3 and records[1].pos0 == "xp1" and records[2].pos0 == "xp2",
    "repeated quotations were not resolved in document order")
expect(records[3].pos0 == "xp3" and records[3].items[1].content == "想法",
    "review abstract fallback or popup items were not preserved")
expect(stats.total == 3 and stats.located == 3 and stats.unmatched == 0,
    "locator statistics are incorrect")

print(("external_annotations_spec: %d checks"):format(checks))
