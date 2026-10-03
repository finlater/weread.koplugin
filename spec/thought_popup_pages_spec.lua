-- Unit tests for weread/ui/thought_popup/pages.lua (PageRenderer): the
-- pagination + page-rendering pipeline shared by the bottom and centered
-- popups. Exercises the real renderer (with mocked koreader deps) so the
-- public layout fields (content_h / text_w / boundaries) are verified.
-- Run from the repo root with:
--   lua spec/thought_popup_pages_spec.lua

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

package.preload["libs/libkoreader-xtext"] = function()
    return {
        new = function(text, face, ...)
            local size = #splitToChars(text)
            local char_width = math.max(1, math.floor(face.size * 0.6))
            local xt = {}
            for i = 1, size do
                xt[i] = true
            end
            xt.measure = function() end
            xt.makeLine = function(_self, idx, width, ...)
                if idx > size then return nil end
                local last = math.min(size, idx + math.max(1, math.floor(width / char_width)) - 1)
                return {
                    offset = idx,
                    end_offset = last,
                    next_start_offset = last + 1,
                    hard_newline_at_eot = false,
                    width = (last - idx + 1) * char_width,
                    targeted_width = width,
                }
            end
            xt.shapeLine = function(_self, first, last)
                local glyphs = { para_is_rtl = false, width = (last - first + 1) * char_width }
                for i = first, last do
                    glyphs[#glyphs + 1] = {
                        font_num = 0, glyph = i, x_advance = char_width,
                        x_offset = 0, y_offset = 0,
                    }
                end
                return glyphs
            end
            xt.free = function(self) self.freed = true end
            setmetatable(xt, { __len = function() return size end })
            return xt
        end,
    }
end

local rules_painted = 0
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
        TYPE_BB8 = 8,
        TYPE_BBRGB32 = 32,
        isColor8 = function() return true end,
        new = function(w, h)
            return {
                fill = function() end,
                blitFrom = function() end,
                paintRect = function(_self, x, y, width, height)
                    assert(x >= 0 and y >= 0 and x + width <= w and y + height <= h)
                    rules_painted = rules_painted + 1
                end,
                getWidth = function() return w end,
                getHeight = function() return h end,
            }
        end,
    }
end

package.preload["device"] = function()
    return {
        screen = {
            scaleBySize = function(_self, v) return v end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            isColorEnabled = function() return false end,
        },
    }
end

local bold_draws, regular_draws = 0, 0
package.preload["ui/rendertext"] = function()
    return { getGlyphByIndex = function(_self, _face, _glyph, bold)
        if bold then bold_draws = bold_draws + 1 else regular_draws = regular_draws + 1 end
        return nil
    end }
end

-- Mock the koreader Cache API used by pages.lua (get/insert/clear +
-- eviction callbacks).
package.preload["cache"] = function()
    return {
        new = function(_self, opts)
            local store = {}
            local cache = {
                get = function(_c, key) return store[key] end,
                insert = function(_c, key, item)
                    store[key] = item
                    local n = 0
                    for _k in pairs(store) do n = n + 1 end
                    if n > (opts.slots or 4) then
                        local k = next(store)
                        if k then
                            if store[k].onFree then store[k]:onFree() end
                            store[k] = nil
                        end
                    end
                end,
                clear = function(_c)
                    for k in pairs(store) do
                        if store[k].onFree then store[k]:onFree() end
                        store[k] = nil
                    end
                end,
            }
            return cache
        end,
    }
end

-- cacheitem is dependency-free; mock the minimal class API.
package.preload["cacheitem"] = function()
    return {
        extend = function(cls, o)
            o = o or {}
            setmetatable(o, cls)
            cls.__index = cls
            return o
        end,
        new = function(cls, o) return cls:extend(o) end,
        onFree = function() end,
    }
end

package.preload["weread.ui.thought_popup.face_factory"] = function()
    return {
        getFace = function(_self, _name, size, variant)
            local ratio = ({ meta = 0.72, likes = 0.68 })[variant] or 0.9
            size = math.max(8, math.floor(size * ratio + 0.5))
            local face = {
                size = size,
                ftsize = { getHeightAndAscender = function() return size, math.floor(size * 0.8) end },
            }
            face.getFallbackFont = function() return face end
            return face
        end,
    }
end

local PageRenderer = require("weread.ui.thought_popup.pages")

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

local function ok(cond, label)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print(string.format("FAIL [%s] %s", current_test, label))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

local items = {
    {
        abstract = "a long quoted abstract that will wrap a few times",
        author = "alice",
        content = string.rep("长内容", 200),
        likes_count = 3,
    },
    {
        abstract = "",
        author = "bob",
        content = "a short second thought",
        likes_count = 0,
    },
}

local function new_renderer()
    return PageRenderer:new{
        items = items,
        doc_font_name = nil,
        doc_font_size = 18,
        doc_margins = { left = 20, right = 20, top = 10, bottom = 10 },
        height_ratio = 0.62,
    }
end

test("ensureLayout exposes the public layout fields", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    ok(type(renderer.content_h) == "number" and renderer.content_h > 0,
        "content_h is a positive number after layout")
    ok(type(renderer.text_w) == "number" and renderer.text_w > 0,
        "text_w is a positive number after layout")
    ok(type(renderer.boundaries) == "table" and #renderer.boundaries > 0,
        "boundaries is a non-empty table after layout")
    ok(type(renderer.layout) == "table" and type(renderer.layout.pieces) == "table",
        "layout exposes the piece list")
end)

test("computePages yields pages for the viewport", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    local starts = renderer:computePages(300)
    ok(type(starts) == "table" and #starts >= 1 and starts[1] == 0,
        "page starts begin at the top")
    local tall_starts = renderer:computePages(80)
    ok(#tall_starts >= #starts,
        "a shorter viewport produces at least as many pages")
end)

test("renderPage produces a page bitmap for each page", function()
    rules_painted, bold_draws, regular_draws = 0, 0, 0
    local renderer = new_renderer()
    renderer:ensureLayout()
    local page_starts = renderer:computePages(300)
    for page_idx = 1, #page_starts do
        local bb = renderer:renderPage(page_idx, page_starts)
        ok(type(bb) == "table" and type(bb.fill) == "function",
            "page " .. page_idx .. " renders a bitmap")
    end
    eq(rules_painted, 1, "the separator is drawn once across all pages")
    ok(bold_draws > 0, "author glyphs are rendered bold")
    ok(regular_draws > 0, "body and likes use regular glyphs")
end)

test("long usernames wrap without overlapping right-aligned likes", function()
    local renderer = PageRenderer:new{
        items = {
            { author = string.rep("长用户名", 12), likes_count = 123456, content = "想法正文" },
        },
        doc_font_size = 22,
        content_width = 280,
        skip_quote = true,
    }
    renderer:ensureLayout()
    local author, likes, body = unpack(renderer.layout.pieces)
    eq(author.variant, "meta", "author starts the thought for long-press lookup")
    ok(author.n_lines > 1, "long author wraps")
    ok(author.width < likes.x, "columns have a gap")
    eq(likes.x + likes.width, renderer.text_w, "likes sit on the right edge")
    eq(author.y + author.baseline, likes.y + likes.baseline, "first baselines align")
    ok(body.y > author.y + author.piece_h, "body begins after the whole author")
    ok(body.y > likes.y + likes.piece_h, "body begins after the whole likes column")
    eq(body.width, renderer.text_w, "body uses the full column width")
end)

test("zero likes leave the whole row available for the username", function()
    local renderer = PageRenderer:new{
        items = { { author = "无赞读者", content = "正文", likes_count = 0 } },
        skip_quote = true,
    }
    renderer:ensureLayout()
    eq(#renderer.layout.pieces, 2, "only author and body")
    eq(renderer.layout.pieces[1].width, renderer.text_w, "author uses the full width")
end)

test("centered pages remove the leading rule and its whitespace", function()
    local renderer = PageRenderer:new{
        items = {
            { author = "读者甲", content = "第一条" },
            { author = "读者乙", content = "第二条想法", likes_count = 123 },
        },
        skip_quote = true,
        doc_font_size = 22,
        hide_leading_separator = true,
    }
    renderer:ensureLayout()
    local pieces = renderer.layout.pieces
    local first_body, separator, author, likes, body = pieces[2], pieces[3], pieces[4], pieces[5], pieces[6]
    local viewport_h = author.y + author.piece_h + 1
    local starts = renderer:computePages(viewport_h)
    eq(#starts, 2, "header without body causes a page break")
    eq(starts[2], first_body.y + first_body.line_h, "break comes before the separator whitespace")
    ok(separator.y >= starts[2], "separator stays on the second page")
    ok(body.y + body.line_h - starts[2] <= viewport_h, "second page fits the first body line")
    eq(separator.y - first_body.y - first_body.piece_h, 12, "12 pixels above rule at preview scale")
    eq(author.y - separator.y - separator.piece_h, 12, "12 pixels below rule at preview scale")
    eq(body.y - math.max(author.y + author.piece_h, likes.y + likes.piece_h), 6, "6 pixels below header")
    rules_painted = 0
    renderer:renderPage(1, starts)
    eq(rules_painted, 0, "previous page has no orphaned rule")
    local second_page = renderer:renderPage(2, starts)
    eq(rules_painted, 0, "following page has no rule above its first thought")
    eq(second_page:getHeight(), renderer.content_h - author.y, "leading whitespace is removed with the rule")
    eq(renderer:getPageContentStart(2, starts), author.y, "paint and touch use the first author's position")
    eq(renderer:renderPage(2, starts), second_page, "revisiting the page reuses its trimmed bitmap")

    renderer:renderPage(1, renderer:computePages(renderer.content_h))
    eq(rules_painted, 1, "the rule remains when both thoughts fit on the same page")
end)

test("setContent with unchanged items keeps the layout", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    local content_h = renderer.content_h
    renderer:setContent(items, nil, 18,
        { left = 20, right = 20, top = 10, bottom = 10 }, 0.62)
    eq(renderer.content_h, content_h, "same content reuses the cached layout")
end)

test("setContent with new items re-lays out", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    local content_h = renderer.content_h
    renderer:setContent({
        { abstract = "", author = "x", content = "短", likes_count = 0 },
    }, nil, 18, { left = 20, right = 20, top = 10, bottom = 10 }, 0.62)
    ok(renderer.content_h < content_h,
        "shorter content re-lays out to a smaller height")
end)

test("setContent with a new content width re-lays out", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    local text_w = renderer.text_w
    renderer:setContent(items, nil, 18,
        { left = 20, right = 20, top = 10, bottom = 10 }, 0.62, 400)
    ok(renderer.text_w < text_w,
        "a narrower content width produces a narrower text column")
end)

test("setContent with a new contrast re-lays out with darker pieces", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    eq(renderer.layout.pieces[1].fg, 6, "default quote gray level")
    renderer:setContent(items, nil, 18,
        { left = 20, right = 20, top = 10, bottom = 10 }, 0.62, nil, 2)
    eq(renderer.layout.pieces[1].fg, 4, "positive contrast darkens the quote")
end)

test("freeContentCaches drops the layout", function()
    local renderer = new_renderer()
    renderer:ensureLayout()
    renderer:freeContentCaches()
    eq(renderer.layout, nil, "layout released")
    eq(renderer.boundaries, nil, "boundaries released")
    -- The renderer stays usable after the caches were freed.
    renderer:ensureLayout()
    ok(renderer.content_h > 0, "re-layout works after freeContentCaches")
end)

print(string.format("thought_popup_pages_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
