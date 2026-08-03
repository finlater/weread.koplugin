-- Unit tests for weread/ui/thought_popup/paginator.lua and content_builder.lua.
-- Run from the repo root with:
--   lua spec/thought_popup_spec.lua

package.path = "./?.lua;" .. package.path

-- Deterministic one-line-per-call xtext mock: every makeLine call consumes the
-- rest of the text as a single line. hard_newline_at_eot is controllable per
-- test through the shared state below.
local mock_xt_state = { hard_newline_at_eot = false }
package.preload["libs/libkoreader-xtext"] = function()
    return {
        new = function(text, face, ...)
            local size = #text
            -- LuaJIT does not honor __len on plain tables, so the mock makes
            -- #xt work by giving xt a contiguous array part of `size` entries
            -- (the real xtext object is userdata with a native __len).
            local xt = {}
            for i = 1, size do
                xt[i] = true
            end
            xt.measure = function() end
            xt.makeLine = function(_self, idx, width, ...)
                if idx > size then
                    return nil
                end
                -- A hard newline at end of text reports no continuation offset
                -- (like the real xtext userdata); otherwise the whole rest of
                -- the text is one line.
                local hard = mock_xt_state.hard_newline_at_eot
                local next_offset = size + 1
                if hard then
                    next_offset = nil
                end
                return {
                    offset = idx,
                    next_start_offset = next_offset,
                    hard_newline_at_eot = hard,
                }
            end
            return xt
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_GRAY_5 = 5,
        COLOR_GRAY_6 = 6,
        COLOR_GRAY_9 = 9,
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
        print(string.format("FAIL [%s] %s: got %s, want %s",
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

test("keep_prev pulls an orphaned protected line to the next page", function()
    -- 4 lines, 20 px each; protected line is line 3 (index 3). With a 40 px
    -- viewport the naive break lands at line 3's top, orphaning line 2's
    -- group; keep_prev must pull the break back one line.
    local b = boundaries(4, 20)
    b[3].keep_prev = true
    local starts = Paginator.computePages(b, 40, 80)
    eq(#starts, 3, "page count")
    eq(starts[2], 20, "page 2 start (pulled back before protected line)")
    eq(starts[3], 60, "page 3 start")
end)

test("keep_prev on the first line never pulls before page start", function()
    local b = boundaries(3, 20)
    b[1].keep_prev = true
    local starts = Paginator.computePages(b, 60, 60)
    eq(#starts, 1, "page count")
    eq(starts[1], 0, "first page start")
end)

test("an oversized first line advances without losing tail content", function()
    -- First "line" is 100 px tall inside a 50 px viewport; the remaining
    -- content must still appear on a later page.
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
            getHeightAndAscender = function() return 30 end,
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
    -- 50 runes + ellipsis + 2 quote marks: bytes are 50 + 3 + 3 + 3.
    eq(#blocks[1].text, 59, "truncated quote byte length")
    eq(blocks[1].text:sub(-6, -1), "…」", "ellipsis closes the quote")
end)

test("content builder handles empty input", function()
    eq(#ContentBuilder.build({}), 0, "no blocks")
    eq(#ContentBuilder.build(nil), 0, "no blocks for nil")
end)

print(string.format("thought_popup_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
