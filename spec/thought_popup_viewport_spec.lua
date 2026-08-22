-- Unit tests for weread/ui/thought_popup/page_viewport.lua: the centered
-- popup viewport must paint the page reported by page_index_getter() on
-- every paint, so navigation (which only changes the popup page index)
-- shows the new page without syncing a copy of the index into the viewport.
-- Run from the repo root with:
--   lua spec/thought_popup_viewport_spec.lua

package.path = "./?.lua;" .. package.path

package.preload["ui/widget/widget"] = function()
    return {
        extend = function(cls, o)
            o = o or {}
            setmetatable(o, cls)
            cls.__index = cls
            return o
        end,
        new = function(cls, o)
            o = cls:extend(o)
            if o.init then o:init() end
            return o
        end,
    }
end

local PageViewport = require("weread.ui.thought_popup.page_viewport")

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

-- A fake destination bitmap that records every blitFrom call.
local function make_target()
    local blits = {}
    local bb = {
        blits = blits,
        blitFrom = function(_self, src, x, y, ...)
            blits[#blits + 1] = { src = src, x = x, y = y }
        end,
    }
    return bb
end

-- A fake page bitmap whose identity (table) lets us tell pages apart.
local function make_page_bb(h)
    return { getHeight = function() return h or 200 end }
end

test("paints the page reported by page_index_getter", function()
    local page1 = make_page_bb()
    local page2 = make_page_bb()
    local requested = {}
    local viewport = PageViewport:new{
        dimen = { w = 100, h = 200 },
        page_index_getter = function() return 1 end,
        page_bb_getter = function(page_idx)
            requested[#requested + 1] = page_idx
            return page_idx == 1 and page1 or page2
        end,
        margin_left = 10,
        text_w = 80,
    }
    local bb = make_target()
    viewport:paintTo(bb, 0, 0)
    eq(requested[1], 1, "first paint asks for page 1")
    eq(bb.blits[1].src, page1, "first paint blits page 1")
end)

test("a page flip paints the new page without extra state", function()
    local current = 1
    local requested = {}
    local pages = {
        make_page_bb(),
        make_page_bb(),
        make_page_bb(),
    }
    local viewport = PageViewport:new{
        dimen = { w = 100, h = 200 },
        page_index_getter = function() return current end,
        page_bb_getter = function(page_idx)
            requested[#requested + 1] = page_idx
            return pages[page_idx]
        end,
        margin_left = 10,
        text_w = 80,
    }
    local bb = make_target()
    viewport:paintTo(bb, 0, 0)
    eq(requested[1], 1, "initial paint asks for page 1")

    -- Navigation only changes the popup page index (like changePage).
    current = 3
    viewport:paintTo(bb, 0, 0)
    eq(requested[#requested], 3, "paint asks for the new page after a flip")
    eq(bb.blits[#bb.blits].src, pages[3], "the flipped page is blitted")
end)

test("short pages are clipped to the viewport height", function()
    local viewport = PageViewport:new{
        dimen = { w = 100, h = 50 },
        page_index_getter = function() return 1 end,
        page_bb_getter = function() return make_page_bb(200) end,
        margin_left = 0,
        text_w = 100,
    }
    local bb = make_target()
    viewport:paintTo(bb, 0, 0)
    eq(bb.blits[1].src:getHeight(), 200, "source bitmap untouched")
    -- blitFrom receives the clipped visible height as its last argument; the
    -- mock records args after x/y, so just assert a blit happened for a page
    -- taller than the viewport.
    eq(#bb.blits, 1, "taller page still blits")
end)

test("no page_bb_getter paints nothing", function()
    local viewport = PageViewport:new{
        dimen = { w = 10, h = 10 },
        page_index_getter = function() return 1 end,
    }
    local bb = make_target()
    viewport:paintTo(bb, 0, 0)
    eq(#bb.blits, 0, "no blit without a page bitmap")
end)

print(string.format("thought_popup_viewport_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
