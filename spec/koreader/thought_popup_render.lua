-- Run from a built KOReader directory, including on Kindle:
-- KO_HOME=/isolated/dir ./luajit /repo/spec/koreader/thought_popup_render.lua /plugin /evidence
-- Uses the device's real LuaJIT, XText, FreeType and Blitbuffer. Only screen
-- geometry and font discovery are supplied here: no framebuffer/input is
-- opened, and no reader settings, books or annotation caches are accessed.
local plugin, evidence = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = plugin .. "/?.lua;" .. package.path
package.loaded["device"] = {
    screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
        scaleBySize = function(_, n) return math.floor(n * 1072 / 600 + 0.5) end,
        isColorEnabled = function() return false end,
    },
}
package.loaded["fontlist"] = {
    fontdir = "./fonts",
    getFontList = function()
        return {
            "./fonts/noto/NotoSans-Regular.ttf",
            "./fonts/noto/NotoSans-Italic.ttf",
            "./fonts/noto/NotoSansCJKsc-Regular.otf",
            "./fonts/freefont/FreeSans.ttf",
            "./fonts/freefont/FreeSerif.ttf",
            "./fonts/nerdfonts/symbols.ttf",
        }
    end,
}
G_reader_settings = require("luasettings"):wrap({})

local Renderer = require("weread.ui.thought_popup.pages")
local items = {
    { author = "读者甲", likes_count = 12,
        content = string.rep("这是用于验证分页的示例想法。保留正文行距，检查下一条评论是否被整体移到新的一页。", 3) },
    { author = "Victoria", content = "这一条恰好从新的一页开始，名字上方不需要分隔线。" },
    { author = "另一位读者", likes_count = 134, content = "同一页的两条想法之间，仍然应该保留细分隔线。" },
}
local function renderer(hide)
    local value = Renderer:new{
        items = items, doc_font_size = 36, content_width = 856,
        doc_margins = { left = 40, right = 40, top = 10, bottom = 10 },
        contrast = 9, skip_quote = true, hide_leading_separator = hide,
    }
    value:ensureLayout()
    return value
end
local function pixel(bb, x, y)
    return bb:getPixel(x, y):getColor8().a
end
local function firstInkY(bb)
    for y = 0, bb:getHeight() - 1 do
        for x = 0, bb:getWidth() - 1 do
            if pixel(bb, x, y) < 255 then return y end
        end
    end
end

local centered = renderer(true)
local authors, separators = {}, {}
for _, piece in ipairs(centered.layout.pieces) do
    if piece.variant == "meta" then authors[#authors + 1] = piece end
    if piece.kind == "separator" then separators[#separators + 1] = piece end
end
local viewport_h = authors[2].y + authors[2].piece_h + 1
local starts = centered:computePages(viewport_h)
assert(#starts == 2, "fixture must have exactly two pages")
assert(starts[2] <= separators[1].y, "second page must start before the first separator")
local first_page = centered:renderPage(1, starts)
local second_page = centered:renderPage(2, starts)
first_page:writePNG(evidence .. "/page-1.png")
second_page:writePNG(evidence .. "/page-2.png")
local x = math.floor(centered.text_w / 2)
local leading_y = separators[1].y - starts[2]
-- The fallback lets the same regression demonstrate the installed old bug.
local origin = centered.getPageContentStart and centered:getPageContentStart(2, starts) or starts[2]
local inner_y = separators[2].y - origin
local author_ink_y = firstInkY(centered:_getPieceTextBB(authors[2]))
print(string.format("native page2: top ink=%d, author ink=%d, removed spacing=%d, inner-rule pixel=%d, pages=%d",
    firstInkY(second_page), author_ink_y, origin - starts[2], pixel(second_page, x, inner_y), #starts))
assert(firstInkY(second_page) == author_ink_y, "page-leading separator whitespace is still present")
assert(origin == authors[2].y, "page touch origin must match its first author")
assert(pixel(second_page, x, inner_y) == separators[2].fg:getColor8().a,
    "in-page separator disappeared")
assert(centered:renderPage(2, starts) == second_page, "cached page must be reused")

-- Page bitmap boundaries must not hide separators during continuous panning.
local scrolling = renderer(false)
local scroll_starts = scrolling:computePages(viewport_h)
local scroll_page = scrolling:renderPage(2, scroll_starts)
assert(pixel(scroll_page, x, leading_y) == separators[1].fg:getColor8().a,
    "continuous-scroll bitmap lost its separator")
scrolling:freeContentCaches()
centered:freeContentCaches()

-- A page continuing the previous thought still keeps a following separator.
local continuation = renderer(true)
local continuation_starts = continuation:computePages(math.floor(viewport_h * 0.6))
local checked = false
for page_idx, start in ipairs(continuation_starts) do
    local finish = continuation_starts[page_idx + 1] or continuation.content_h
    if start < separators[1].y and separators[1].y < finish and start > authors[1].piece_h then
        local bb = continuation:renderPage(page_idx, continuation_starts)
        local content_start = continuation:getPageContentStart(page_idx, continuation_starts)
        assert(content_start == start, "continued text must not be trimmed")
        assert(pixel(bb, x, separators[1].y - content_start) == separators[1].fg:getColor8().a,
            "separator after continued text disappeared")
        checked = true
    end
end
assert(checked, "fixture must cover a separator after continued text")
continuation:freeContentCaches()
print("PASS: native page-top whitespace, in-page/continuous-scroll/continued-text separators and bitmap cache")
