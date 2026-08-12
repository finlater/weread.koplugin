-- D-pad focus navigation for the plugin's full-screen views.
--
-- KOReader's FocusManager supplies the key mappings (arrows, Press, Alt+
-- arrows, Tab...) and the Focus/Unfocus highlight protocol, and our views
-- extend it directly. This module only wires a view's focus layout and keeps
-- the focused row inside its scroll area -- the two pieces FocusManager does
-- not provide for scrollable lists.

local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local bit = require("bit")

local M = {}

-- rows: array of rows, each an array of focusable widgets in visual order.
-- A widget must react to onFocus()/onUnfocus() (Button does natively) and
-- expose a tap gesture that triggers its action (that is how Press activates).
-- options.scroll: ScrollableContainer that owns some of the rows.
-- options.outside_scroll: hash of widgets living outside that container.
function M.apply(view, rows, options)
    options = options or {}
    view.layout = rows
    view._nav_scroll = options.scroll
    view._nav_outside_scroll = options.outside_scroll or {}
    if options.scroll and options.scroll.key_events then
        -- ScrollableContainer registers ScrollPageUp/Down for PgBack/PgFwd,
        -- and events propagate children-first: the container would swallow
        -- the paging keys before this view's NextPage/PrevPage handlers run.
        -- Drop its claim so paging moves the focus instead of just scrolling.
        options.scroll.key_events.ScrollPageUp = nil
        options.scroll.key_events.ScrollPageDown = nil
    end
    view.onFocusMove = function(self, args)
        local handled = FocusManager.onFocusMove(self, args)
        if handled then M.scrollToFocused(self) end
        return handled
    end
    if Device:hasKeys() then
        -- FocusManager only maps D-pad keys; on keypad devices with physical
        -- paging keys (Kindle et al.) PgFwd/PgBack would otherwise die.
        -- We follow Menu's convention of NextPage/PrevPage key events.
        view.key_events.NextPage = { { Device.input.group.PgFwd } }
        view.key_events.PrevPage = { { Device.input.group.PgBack } }
        view.onNextPage = function(self) return M.pageFocus(self, 1) end
        view.onPrevPage = function(self) return M.pageFocus(self, -1) end
    end
end

-- Move the focus by one viewport per PgFwd/PgBack press, then scroll so the
-- focused row becomes the first row of the new page (like Menu's paging).
-- Without a scroll area the step degenerates to a single row.
function M.pageFocus(view, direction)
    local scroll = view._nav_scroll
    if not scroll then
        return view.onFocusMove(view, { 0, direction })
    end
    local step = M.pageStep(view)
    if step <= 1 then
        return view.onFocusMove(view, { 0, direction })
    end
    -- Clamp instead of wrapping: paging past the end stops at the last row
    -- instead of jumping back to the top of the list.
    local target_y = math.max(1, math.min(view.selected.y + direction * step, #view.layout))
    if target_y ~= view.selected.y then
        local target_row = view.layout[target_y]
        local target_x = math.min(view.selected.x, #target_row)
        view:moveFocusTo(target_x, target_y, FocusManager.FORCED_FOCUS)
    end
    M.scrollFocusedToTop(view)
    return true
end

-- Rows that fit in one viewport; used to estimate how far a page move jumps.
function M.pageStep(view)
    local scroll = view._nav_scroll
    local item = view:getFocusItem()
    if not scroll or not item or not item.dimen or not item.dimen.h
        or item.dimen.h <= 0 then
        return 1
    end
    local area = scroll.dimen
    if not area or not area.h then return 1 end
    return math.max(1, math.floor(area.h / item.dimen.h))
end

-- Scroll the focused row to the top of the scroll area, making it the first
-- row of the newly paged viewport.
function M.scrollFocusedToTop(view)
    local scroll = view._nav_scroll
    local item = view:getFocusItem()
    if not scroll or not item or view._nav_outside_scroll[item] then return end
    local row = item.dimen
    local area = scroll.dimen
    if not row or not area or not area.h then return end
    scroll:_scrollBy(0, row.y - area.y)
end

-- Keep the focused widget fully inside the scroll area, scrolling minimally.
function M.scrollToFocused(view)
    local scroll = view._nav_scroll
    local item = view:getFocusItem()
    if not scroll or not item or view._nav_outside_scroll[item] then return end
    local row = item.dimen
    local area = scroll.dimen
    if not row or not area or not area.h then return end
    if row.y < area.y then
        scroll:_scrollBy(0, row.y - area.y)
    elseif row.y + row.h > area.y + area.h then
        scroll:_scrollBy(0, row.y + row.h - area.y - area.h)
    end
end

-- Show the cursor on non-touch devices only; on touch devices key navigation
-- still works but the initial selection stays invisible.
-- NOT_UNFOCUS is set so the initial placement never sends Unfocus to the
-- placeholder item at (1, 1): on touch+key devices that would clear the
-- preselect highlight of whichever tab happens to sit there.
function M.initialFocus(view, x, y)
    view:moveFocusTo(x or 1, y or 1,
        bit.bor(FocusManager.FOCUS_ONLY_ON_NT, FocusManager.NOT_UNFOCUS))
end

return M
