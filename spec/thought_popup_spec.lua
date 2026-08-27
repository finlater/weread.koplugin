-- Unit tests for weread/ui/thought_popup/paginator.lua and content_builder.lua.
-- Run from the repo root with:
--   lua spec/thought_popup_spec.lua

package.path = "./?.lua;" .. package.path

local function splitToChars(str)
    local chars = {}
    local i = 1
    while i <= #str do
        local b = str:byte(i)
        local rune_len
        if b < 0x80 then rune_len = 1
        elseif b < 0xE0 then rune_len = 2
        elseif b < 0xF0 then rune_len = 3
        else rune_len = 4 end
        chars[#chars + 1] = str:sub(i, i + rune_len - 1)
        i = i + rune_len
    end
    return chars
end

local function bsearch_left(t, v)
    local lo, hi = 1, #t + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if t[mid] < v then lo = mid + 1 else hi = mid end
    end
    return lo
end

local function bsearch_right(t, v)
    local lo, hi = 1, #t + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if t[mid] <= v then lo = mid + 1 else hi = mid end
    end
    return lo
end

package.preload["util"] = function()
    return {
        splitToChars = splitToChars,
        bsearch_left = bsearch_left,
        bsearch_right = bsearch_right,
    }
end

local mock_xt_state = { hard_newline_at_eot = false }
package.preload["libs/libkoreader-xtext"] = function()
    return {
        new = function(text, face, ...)
            local size = #text
            local xt = {}
            for i = 1, size do
                xt[i] = true
            end
            xt.measure = function() end
            xt.makeLine = function(_self, idx, width, ...)
                if idx > size then
                    return nil
                end
                local hard = mock_xt_state.hard_newline_at_eot
                local next_offset = size + 1
                if hard then
                    next_offset = nil
                end
                return {
                    offset = idx,
                    end_offset = size,
                    next_start_offset = next_offset,
                    hard_newline_at_eot = hard,
                    width = width,
                    targeted_width = width,
                }
            end
            xt.shapeLine = function()
                return { para_is_rtl = false, width = 0 }
            end
            xt.free = function(self)
                self.freed = true
            end
            setmetatable(xt, { __len = function() return size end })
            return xt
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_GRAY_1 = 1,
        COLOR_GRAY_2 = 2,
        COLOR_GRAY_3 = 3,
        COLOR_GRAY_4 = 4,
        COLOR_GRAY_5 = 5,
        COLOR_GRAY_6 = 6,
        COLOR_GRAY_7 = 7,
        COLOR_DARK_GRAY = 8,
        COLOR_GRAY_9 = 9,
        COLOR_GRAY = 10,
        COLOR_GRAY_B = 11,
        COLOR_LIGHT_GRAY = 12,
        COLOR_GRAY_D = 13,
        COLOR_GRAY_E = 14,
        COLOR_BLACK = 0,
        COLOR_WHITE = 255,
        isColor8 = function() return true end,
        new = function() return { fill = function() end } end,
    }
end

local Paginator = require("weread.ui.thought_popup.paginator")
local ContentBuilder = require("weread.ui.thought_popup.content_builder")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        io.stderr:write(string.format("FAIL [%s] %s: got %s want %s\n",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local function boundaries(n, line_h)
    local out = {}
    for k = 1, n do
        out[k] = {
            top = (k - 1) * line_h,
            bottom = k * line_h,
        }
    end
    return out
end

test("empty boundaries yield a single page", function()
    local starts = Paginator.computePages({}, 100, 100)
    eq(#starts, 1, "page count")
    eq(starts[1], 0, "first page start")
end)

test("content that fits one viewport stays one page", function()
    local starts = Paginator.computePages(boundaries(3, 20), 100, 60)
    eq(#starts, 1, "page count")
    eq(starts[1], 0, "first page start")
end)

test("page breaks land on line boundaries", function()
    local starts = Paginator.computePages(boundaries(10, 20), 60, 200)
    eq(#starts, 4, "page count")
    eq(starts[1], 0, "page 1 start")
    eq(starts[2], 60, "page 2 start")
    eq(starts[3], 120, "page 3 start")
    eq(starts[4], 180, "page 4 start")
end)

test("keep_next pulls an orphaned author line to the next page", function()
    local b = {
        { top = 0, bottom = 61 },
        { top = 61, bottom = 122 },
        { top = 122, bottom = 183 },
        { top = 183, bottom = 244, keep_next = true },
        { top = 244, bottom = 305 },
        { top = 305, bottom = 366 },
    }
    local starts = Paginator.computePages(b, 300, 366)
    eq(#starts, 2, "page count")
    eq(starts[2], 183, "page 2 start (pulled back before author line)")
end)

test("multi-line author piece stays whole with keep_next", function()
    local b = {
        { top = 0, bottom = 61 },
        { top = 61, bottom = 122 },
        { top = 122, bottom = 244, keep_next = true },
        { top = 244, bottom = 305 },
        { top = 305, bottom = 366 },
    }
    local starts = Paginator.computePages(b, 300, 366)
    eq(#starts, 2, "page count")
    eq(starts[2], 122, "author block kept together")
end)

test("keep_next on the first line never pulls before page start", function()
    local b = boundaries(3, 20)
    b[1].keep_next = true
    local starts = Paginator.computePages(b, 60, 60)
    eq(#starts, 1, "page count")
    eq(starts[1], 0, "first page start")
end)

test("an oversized first line advances without losing tail content", function()
    local b = {
        { top = 0, bottom = 100 },
        { top = 100, bottom = 120 },
        { top = 120, bottom = 140 },
        { top = 140, bottom = 160 },
    }
    local starts = Paginator.computePages(b, 50, 160)
    eq(#starts, 3, "page count")
    eq(starts[1], 0, "page 1 start")
    eq(starts[2], 100, "page 2 start (after oversized line)")
    eq(starts[3], 140, "page 3 start")
end)

test("pieceVisibleRange clips text to the page window", function()
    local piece = {
        kind = "text",
        y = 20,
        piece_h = 60,
        line_h = 20,
        n_lines = 3,
        width = 100,
    }
    local r = Paginator.pieceVisibleRange(piece, 0, 60)
    eq(r.k0, 0, "first clipped line index")
    eq(r.k1, 1, "last clipped line index")
    eq(r.src_y, 0, "source y")
    eq(r.src_h, 40, "source height")
    eq(r.dest_y, 20, "destination y")
end)

test("pieceVisibleRange returns nil when outside the page", function()
    local piece = {
        kind = "text",
        y = 200,
        piece_h = 20,
        line_h = 20,
        n_lines = 1,
        width = 100,
    }
    eq(Paginator.pieceVisibleRange(piece, 0, 60), nil, "below page window")
end)

test("textPieceMetrics folds glyph overhang into the piece height", function()
    local face = {
        size = 20,
        ftsize = {
            getHeightAndAscender = function() return 30, 24 end,
        },
    }
    local line_h, extra = Paginator.textPieceMetrics(face)
    eq(line_h, 24, "line height (1.2 * size, rounded)")
    eq(extra, 6, "glyph overhang")
end)

test("paginateLines counts one line per text run", function()
    local face = { size = 20 }
    eq(Paginator.paginateLines("hello world", face, 400), 1, "single line")
    eq(Paginator.paginateLines("", face, 400), 0, "empty text")
end)

test("paginateLines adds a trailing line for a hard newline at end of text", function()
    mock_xt_state.hard_newline_at_eot = true
    local face = { size = 20 }
    eq(Paginator.paginateLines("hello\n", face, 400), 2, "trailing blank line")
    mock_xt_state.hard_newline_at_eot = false
end)

test("paginateText returns reusable xtext and lines", function()
    local face = { size = 20 }
    local pt = Paginator.paginateText("hello", face, 400)
    eq(pt.n_lines, 1, "line count")
    eq(type(pt.xtext), "table", "xtext present")
    eq(#pt.lines, 1, "lines table length")
    local piece = { xtext = pt.xtext, lines = pt.lines }
    local xt_ref = piece.xtext
    Paginator.freeTextPieces({ piece })
    eq(piece.xtext, nil, "xtext cleared")
    eq(piece.lines, nil, "lines cleared")
    eq(xt_ref.freed, true, "xtext freed")
end)

test("buildPagePieceIndex maps pieces to pages", function()
    local pieces = {
        { y = 0, piece_h = 30 },
        { y = 50, piece_h = 30 },
        { y = 120, piece_h = 30 },
    }
    local pages = { 0, 60, 120 }
    local index = Paginator.buildPagePieceIndex(pieces, pages, 150)
    eq(#index[1], 2, "page 1 has two pieces")
    eq(#index[2], 1, "page 2 has one piece")
    eq(#index[3], 1, "page 3 has one piece")
end)

test("a single long thought spans multiple pages", function()
    -- 60 line boundaries from ONE content piece; a 300px viewport shows
    -- about three lines at a time, so the piece flows across 4 pages.
    local starts = Paginator.computePages(boundaries(60, 20), 300, 1200)
    eq(#starts, 4, "long single piece paginates across 4 pages")
    eq(starts[1], 0, "page 1 starts at the top")
    eq(starts[4], 900, "page 4 starts at the content bottom minus one viewport")
end)

test("a long piece is indexed into every page it spans", function()
    -- The piece covers y in [0, 150), i.e. all three 60px pages.
    local piece = { y = 0, piece_h = 150 }
    local pages = { 0, 60, 120 }
    local index = Paginator.buildPagePieceIndex({ piece }, pages, 150)
    eq(#index[1], 1, "page 1 includes the piece")
    eq(#index[2], 1, "page 2 includes the piece")
    eq(#index[3], 1, "page 3 includes the piece")
end)

test("content builder emits quote, meta and content blocks", function()
    local blocks = ContentBuilder.build({
        {
            abstract = "quote text",
            author = "alice",
            content = "body text",
            likes_count = 3,
        },
    })
    eq(#blocks, 3, "block count")
    eq(blocks[1].kind, "paragraph", "quote kind")
    eq(blocks[1].variant, "quote", "quote variant")
    eq(blocks[1].text, "「quote text」", "quote text")
    eq(blocks[1].fg, 6, "quote gray level")
    eq(blocks[2].variant, "meta", "meta variant")
    eq(blocks[2].text, "▸ alice · ♥ 3", "meta text with likes")
    eq(blocks[2].spacing_after, 0.18, "meta separates author from body")
    eq(blocks[3].variant, "content", "content variant")
    eq(blocks[3].text, "body text", "content text")
end)

test("content builder skips empty content and zero likes", function()
    local blocks = ContentBuilder.build({
        {
            abstract = "",
            author = "bob",
            content = "  ",
            likes_count = 0,
        },
    })
    eq(#blocks, 1, "only the meta block remains")
    eq(blocks[1].variant, "meta", "meta variant")
    eq(blocks[1].text, "▸ bob", "meta text without likes")
end)

test("content builder truncates multi-paragraph and long quotes", function()
    local long = string.rep("a", 60)
    local blocks = ContentBuilder.build({
        {
            abstract = long .. "\nsecond paragraph",
            author = "carol",
            content = "x",
            likes_count = 0,
        },
    })
    eq(blocks[1].variant, "quote", "quote variant")
    eq(#blocks[1].text, 59, "truncated quote byte length")
    eq(blocks[1].text:sub(-6, -1), "…」", "ellipsis closes the quote")

    local cjk = string.rep("汉", 60)
    blocks = ContentBuilder.build({
        {
            abstract = cjk,
            author = "dan",
            content = "x",
            likes_count = 0,
        },
    })
    eq(blocks[1].text, "「" .. string.rep("汉", 50) .. "…」", "cjk quote truncation")
end)

test("content builder strips unicode trailing whitespace", function()
    local ZWNJ = "\226\128\140"
    local blocks = ContentBuilder.build({
        {
            abstract = "",
            author = "a",
            content = "hello\n" .. ZWNJ,
            likes_count = 0,
        },
    })
    eq(blocks[2].text, "hello", "trailing zwnj stripped from content")
end)


test("content builder handles empty input", function()
    eq(#ContentBuilder.build({}), 0, "no blocks")
    eq(#ContentBuilder.build(nil), 0, "no blocks for nil")
end)

test("content builder contrast darkens and lightens every block", function()
    local items = {
        { abstract = "q", author = "a", content = "c", likes_count = 0 },
    }
    local dark = ContentBuilder.build(items, 2)
    eq(dark[1].fg, 4, "quote darkens two levels")
    eq(dark[2].fg, 7, "meta darkens two levels")
    eq(dark[3].fg, 3, "content darkens two levels")
    local light = ContentBuilder.build(items, -2)
    eq(light[1].fg, 8, "quote lightens two levels")
    eq(light[2].fg, 11, "meta lightens two levels")
    eq(light[3].fg, 7, "content lightens two levels")
end)

test("content builder contrast clamps to the gray palette", function()
    local items = {
        { abstract = "", author = "a", content = "c", likes_count = 0 },
    }
    local very_dark = ContentBuilder.build(items, 10)
    eq(very_dark[2].fg, 0, "content clamps at pure black")
    local very_light = ContentBuilder.build(items, -10)
    eq(very_light[2].fg, 255, "content clamps at the lightest level")
end)

test("content builder maximum contrast renders pure black", function()
    local items = {
        { abstract = "q", author = "a", content = "c", likes_count = 0 },
    }
    local blocks = ContentBuilder.build(items, 9)
    eq(blocks[1].fg, 0, "quote is pure black at maximum contrast")
    eq(blocks[2].fg, 0, "meta is pure black at maximum contrast")
    eq(blocks[3].fg, 0, "content is pure black at maximum contrast")
end)

print(string.format("thought_popup_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
