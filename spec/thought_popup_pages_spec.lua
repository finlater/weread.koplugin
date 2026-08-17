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
        new = function(text, _face, ...)
            local size = #text
            local xt = {}
            for i = 1, size do
                xt[i] = true
            end
            xt.measure = function() end
            xt.makeLine = function(_self, idx, width, ...)
                if idx > size then return nil end
                return {
                    offset = idx,
                    end_offset = size,
                    next_start_offset = size + 1,
                    hard_newline_at_eot = false,
                    width = width,
                    targeted_width = width,
                }
            end
            xt.shapeLine = function()
                return { para_is_rtl = false, width = 0 }
            end
            xt.free = function(self) self.freed = true end
            setmetatable(xt, { __len = function() return size end })
            return xt
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_GRAY_5 = 5,
        COLOR_GRAY_6 = 6,
        COLOR_GRAY_9 = 9,
        COLOR_BLACK = 0,
        COLOR_WHITE = 255,
        TYPE_BB8 = 8,
        TYPE_BBRGB32 = 32,
        isColor8 = function() return true end,
        new = function(w, h)
            return {
                fill = function() end,
                blitFrom = function() end,
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

package.preload["ui/rendertext"] = function()
    return { getGlyphByIndex = function() return nil end }
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
        getFace = function(_name, _size, _variant)
            return {
                size = 20,
                ftsize = { getHeightAndAscender = function() return 30, 24 end },
            }
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
    local renderer = new_renderer()
    renderer:ensureLayout()
    local page_starts = renderer:computePages(300)
    for page_idx = 1, #page_starts do
        local bb = renderer:renderPage(page_idx, page_starts)
        ok(type(bb) == "table" and type(bb.fill) == "function",
            "page " .. page_idx .. " renders a bitmap")
    end
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
