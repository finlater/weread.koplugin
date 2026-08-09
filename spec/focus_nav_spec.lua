-- Focus-nav wiring tests: layout assignment, scroll-into-view math, and the
-- initial-focus call, exercised against a stubbed FocusManager.

package.path = "./?.lua;" .. package.path

local bit = require("bit")

local focus_moves = {}
local focus_flags = {}
local scroll_calls = {}

package.preload["device"] = function()
    return {
        hasKeys = function() return true end,
        input = {
            group = {
                PgFwd = "PgFwd",
                PgBack = "PgBack",
                Back = "Back",
            },
        },
    }
end

package.preload["ui/widget/focusmanager"] = function()
    return {
        FOCUS_ONLY_ON_NT = 0,
        NOT_UNFOCUS = 1,
        NOT_FOCUS = 2,
        FORCED_FOCUS = 4,
        onFocusMove = function(self, args)
            focus_moves[#focus_moves + 1] = { args[1], args[2] }
            local new_y = self.selected.y + args[2]
            if new_y >= 1 and new_y <= #self.layout then
                self.selected.y = new_y
            end
            return true
        end,
    }
end

local FocusNav = require("weread.ui.focus_nav")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function make_view()
    local w1 = { name = "widgetA" }
    local w2 = { name = "widgetB" }
    local layout = {
        { w1 },
        { w2 },
    }
    local view = {
        layout = layout,
        key_events = {},
        selected = { x = 1, y = 2 },
        getFocusItem = function(self)
            local row = self.layout[self.selected.y]
            return row and row[self.selected.x] or nil
        end,
        moveFocusTo = function(self, x, y, flags)
            focus_flags[#focus_flags + 1] = { x = x, y = y, flags = flags }
            self.selected.x = x
            self.selected.y = y
        end,
    }
    return view, w1, w2
end

local function make_scroll()
    return {
        dimen = { x = 0, y = 50, w = 300, h = 200 },
        _scrollBy = function(_self, dx, dy)
            scroll_calls[#scroll_calls + 1] = { dx = dx, dy = dy }
        end,
    }
end

-- apply wires the layout and the scroll-aware onFocusMove wrapper
focus_moves = {}
local scroll = make_scroll()
local view, w1, w2 = make_view()
local outside = { [w2] = true }
scroll.key_events = {
    ScrollPageUp = { { "RPgBack", "LPgBack" } },
    ScrollPageDown = { { "RPgFwd", "LPgFwd" } },
}
FocusNav.apply(view, {
    { w1 },
    { w2 },
}, { scroll = scroll, outside_scroll = outside })
expect(view.layout[1][1] == w1 and view.layout[2][1] == w2,
    "apply stores the focus layout")
expect(view._nav_scroll == scroll and view._nav_outside_scroll == outside,
    "apply stores the scroll container and outside-scroll set")
expect(scroll.key_events.ScrollPageUp == nil
    and scroll.key_events.ScrollPageDown == nil,
    "apply drops the scroll container's PgFwd/PgBack claim so the view's " ..
    "NextPage/PrevPage handlers can receive the keys")
local handled = view.onFocusMove(view, { 0, 1 })
expect(handled == true, "wrapped onFocusMove still reports handled")
expect(focus_moves[1][1] == 0 and focus_moves[1][2] == 1,
    "wrapped onFocusMove delegates to FocusManager")

-- On keypad devices, PgFwd/PgBack are wired to page the focus; FocusManager
-- itself never maps them (it only maps D-pad keys), so without this the
-- paging keys would be dead in the plugin's views.
expect(view.key_events.NextPage[1][1] == "PgFwd"
    and view.key_events.PrevPage[1][1] == "PgBack",
    "apply maps PgFwd/PgBack to NextPage/PrevPage key events")
expect(type(view.onNextPage) == "function" and type(view.onPrevPage) == "function",
    "apply installs NextPage/PrevPage handlers")

-- pageStep estimates one viewport of rows
focus_moves = {}
local tall_view, tall_w1, tall_w2, tall_w3, tall_w4, tall_w5, tall_w6
do
    tall_w1 = { name = "row1", dimen = { y = 0, h = 30 } }
    tall_w2 = { name = "row2", dimen = { y = 30, h = 30 } }
    tall_w3 = { name = "row3", dimen = { y = 60, h = 30 } }
    tall_w4 = { name = "row4", dimen = { y = 90, h = 30 } }
    tall_w5 = { name = "row5", dimen = { y = 120, h = 30 } }
    tall_w6 = { name = "row6", dimen = { y = 150, h = 30 } }
    tall_view = make_view()
    tall_view.layout = {
        { tall_w1 }, { tall_w2 }, { tall_w3 },
        { tall_w4 }, { tall_w5 }, { tall_w6 },
    }
    tall_view.selected.y = 1
    FocusNav.apply(tall_view, tall_view.layout,
        { scroll = make_scroll() })
end
-- scroll area h=200, row h=30 -> floor(200/30) = 6
expect(FocusNav.pageStep(tall_view) == 6,
    "pageStep returns one viewport of rows")

-- PgFwd jumps the focus by one viewport, then scrolls it to the top of the
-- area so the focused row becomes the first row of the new page
focus_flags = {}
scroll_calls = {}
expect(tall_view.onNextPage(tall_view) == true, "onNextPage reports handled")
expect(tall_view.selected.y == 6,
    "onNextPage moves the focus by one viewport")
expect(#focus_flags == 1 and focus_flags[1].y == 6
    and focus_flags[1].flags == 4,
    "onNextPage pins the focus to the new page's first row")
expect(#scroll_calls == 1 and scroll_calls[1].dy == 100,
    "onNextPage scrolls the focused row to the top of the viewport")

-- PgBack pages back up, never above the first row
focus_flags = {}
scroll_calls = {}
tall_view.selected.y = 6
expect(tall_view.onPrevPage(tall_view) == true, "onPrevPage reports handled")
expect(tall_view.selected.y == 1, "onPrevPage moves the focus back up")
expect(#focus_flags == 1 and focus_flags[1].y == 1,
    "onPrevPage clamps to the first row")
expect(#scroll_calls == 1 and scroll_calls[1].dy == -50,
    "onPrevPage scrolls the focused row to the top")

-- Paging past the end clamps to the last row instead of wrapping around to
-- the top of the list
focus_flags = {}
local end_view = make_view()
end_view.layout = tall_view.layout
end_view.selected.y = 5
FocusNav.apply(end_view, end_view.layout, { scroll = make_scroll() })
expect(end_view.onNextPage(end_view) == true,
    "end-of-list onNextPage reports handled")
expect(end_view.selected.y == 6,
    "paging past the end stops at the last row")

-- Paging from a multi-column toolbar into single-column content keeps the
-- closest valid column instead of asking FocusManager for a missing widget.
focus_flags = {}
local multi_view, multi_w1, multi_w2 = make_view()
multi_w1.dimen = { y = 0, h = 100 }
multi_w2.dimen = { y = 0, h = 100 }
local list_w1 = { name = "list1", dimen = { y = 150, h = 30 } }
local list_w2 = { name = "list2", dimen = { y = 180, h = 30 } }
multi_view.layout = { { multi_w1, multi_w2 }, { list_w1 }, { list_w2 } }
multi_view.selected.x = 2
multi_view.selected.y = 1
FocusNav.apply(multi_view, multi_view.layout, { scroll = make_scroll() })
expect(multi_view.onNextPage(multi_view) == true,
    "multi-column onNextPage reports handled")
expect(multi_view.selected.x == 1 and multi_view.selected.y == 3,
    "paging into a narrower row selects its closest valid column")
expect(#focus_flags == 1 and focus_flags[1].x == 1
    and focus_flags[1].y == 3,
    "paging never asks FocusManager to focus a missing column")

-- Short lists without row heights fall back to single-row moves
focus_moves = {}
local short_view, s1, s2 = make_view()
short_view.selected.y = 2
FocusNav.apply(short_view, { { s1 }, { s2 } }, { scroll = make_scroll() })
expect(short_view.onNextPage(short_view) == true,
    "short-list onNextPage reports handled")
expect(short_view.selected.y == 2,
    "short-list paging clamps at the end of the list")

-- Without a scroll area (e.g. read stats), paging falls back to one row
focus_moves = {}
local plain_view = make_view()
plain_view.selected.y = 1
FocusNav.apply(plain_view, { { w1 }, { w2 } })
expect(FocusNav.pageStep(plain_view) == 1,
    "pageStep falls back to one row without a scroll area")
expect(plain_view.onNextPage(plain_view) == true, "plain onNextPage works")
expect(plain_view.selected.y == 2, "plain onNextPage moves one row")

-- scrollToFocused scrolls only rows that are genuinely outside the area
scroll_calls = {}
view.selected.y = 2
view.layout[2][1] = { dimen = { x = 0, y = 60, w = 300, h = 30 } }
FocusNav.scrollToFocused(view)
expect(#scroll_calls == 0, "fully visible row does not trigger a scroll")

view.layout[2][1] = { dimen = { x = 0, y = 30, w = 300, h = 30 } }
FocusNav.scrollToFocused(view)
expect(#scroll_calls == 1 and scroll_calls[1].dy == -20,
    "row above the area scrolls up by the overflowing amount")

scroll_calls = {}
view.layout[2][1] = { dimen = { x = 0, y = 300, w = 300, h = 30 } }
FocusNav.scrollToFocused(view)
expect(#scroll_calls == 1 and scroll_calls[1].dy == 80,
    "row below the area scrolls down by the overflowing amount")

scroll_calls = {}
view.layout[2][1] = w2
view.selected.y = 2
w2.dimen = { x = 0, y = 30, w = 300, h = 30 }
FocusNav.scrollToFocused(view)
expect(#scroll_calls == 0,
    "widgets marked outside the scroll area are never scrolled")

-- initialFocus pins the cursor with the non-touch-only focus flag, and never
-- unfocuses the placeholder item (so preselect highlights are preserved on
-- touch devices with keys)
focus_flags = {}
FocusNav.initialFocus(view, 1, 2)
expect(focus_flags[1].x == 1 and focus_flags[1].y == 2
    and focus_flags[1].flags == bit.bor(0, 1),
    "initialFocus asks FocusManager for the cursor position without unfocus")

print(string.format(
    "focus_nav_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
