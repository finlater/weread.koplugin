--[[--
Thought popup content viewport.

KOReader has no generic scroll view; scrollable text is only ScrollTextWidget,
which wraps a single TextBoxWidget. This component drops already-rendered page
bitmaps of the content into a viewport:

  * swipe up/down = page-scroll by one viewport height (direct scrolling,
    no button navigation)
  * pan = pixel-level continuous scrolling
  * right-side VerticalScrollBar shows the position and jumps on tap
  * when the content is not taller than the viewport (shrink mode) scrolling
    is a no-op, but gestures are still consumed so west/east swipes propagate
    to the outer widget and close the popup.

Event semantics: north/south are consumed here; west/east return false and
propagate upward (the outer SwipeClose closes the popup).
--]]

local BD = require("ui/bidi")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Paginator = require("weread.ui.thought_popup.paginator")
local util = require("util")
local UIManager = require("ui/uimanager")
local VerticalScrollBar = require("ui/widget/verticalscrollbar")
local Screen = Device.screen
local Input = Device.input

local ScrollContainer = InputContainer:extend{
    page_bb_getter = nil,   -- function(page_idx) -> Blitbuffer, renders lazily
    content_h = 0,          -- total content height
    viewport_h = 0,         -- viewport height
    scroll_offset = 0,      -- current scroll offset (content coords, 0 = top)
    scrollbar_w = Screen:scaleBySize(6),
    margin_left = 0,        -- content left margin (doc_margins.left)
    text_w = 0,             -- content draw width
    dialog = nil,
    -- Page-break boundary table: { {top, bottom, keep_next?} } in y order.
    -- Page steps land only on boundaries so a line is never split across pages.
    boundaries = nil,
    pages = nil,            -- page start list (computed from boundaries + viewport_h)
}

function ScrollContainer:init()
    self.dimen = Geom:new{
        w = Screen:getWidth(),
        h = self.viewport_h,
    }
    local max_offset = math.max(0, self.content_h - self.viewport_h)
    self.max_offset = max_offset
    self.scroll_offset = math.min(self.scroll_offset, max_offset)
    self.pages = self:_computePages()

    self.v_scroll_bar = VerticalScrollBar:new{
        enable = max_offset > 0,
        width = self.scrollbar_w,
        height = self.viewport_h,
        scroll_callback = function(ratio)
            self:scrollToRatio(ratio)
        end,
    }
    -- Attach as a child: VerticalScrollBar sets its touch_dimen (gesture range
    -- and ratio base) in paintTo, but gestures are only dispatched to nodes in
    -- the widget tree — stored as a named field the drag/tap would never fire.
    self[1] = self.v_scroll_bar
    self:_updateScrollBar()

    if Device:isTouchDevice() then
        self.ges_events = {
            ScrollText = {
                GestureRange:new{
                    ges = "swipe",
                    range = function() return self.dimen end,
                },
            },
            TapScrollText = { -- tap left/right half to page up/down
                GestureRange:new{
                    ges = "tap",
                    range = function() return self.dimen end,
                },
            },
            PanText = {
                GestureRange:new{
                    ges = "pan",
                    range = function() return self.dimen end,
                },
            },
            PanReleaseText = {
                GestureRange:new{
                    ges = "pan_release",
                    range = function() return self.dimen end,
                },
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            ScrollDown = { { Input.group.PgFwd } },
            ScrollUp = { { Input.group.PgBack } },
        }
    end
end

--- Page start list from the boundary table (pure logic, see paginator.lua).
function ScrollContainer:_computePages()
    return Paginator.computePages(self.boundaries, self.viewport_h, self.content_h)
end

--- 1-based page index of the current offset.
function ScrollContainer:_currentPageIndex()
    local pages = self.pages
    if not pages or #pages == 0 then return 1 end
    local idx = util.bsearch_right(pages, self.scroll_offset + 1) - 1
    if idx < 1 then return 1 end
    return idx
end

--- Step one page (delta=+1 forward / -1 backward). Page starts are line
--- boundaries, so lines are never split.
function ScrollContainer:scrollToPage(delta)
    local pages = self.pages
    if not pages or #pages < 2 then return end
    local cur = self:_currentPageIndex()
    local target = math.min(#pages, math.max(1, cur + delta))
    if target ~= cur then
        self:_setOffset(pages[target])
    end
end

function ScrollContainer:_updateScrollBar()
    if not self.v_scroll_bar then return end
    local pages = self.pages
    if not pages or #pages == 0 then return end
    -- Position by page index.
    local cur = self:_currentPageIndex()
    local low = (cur - 1) / #pages
    local high = cur / #pages
    self.v_scroll_bar:set(low, high)
end

function ScrollContainer:scrollBy(delta)
    local max_offset = math.max(0, self.content_h - self.viewport_h)
    local new_offset = math.min(max_offset, math.max(0, self.scroll_offset + delta))
    if new_offset ~= self.scroll_offset then
        self.scroll_offset = new_offset
        self:_updateScrollBar()
        if self.dialog then
            UIManager:setDirty(self.dialog, function()
                return "partial", self.dimen
            end)
        end
    end
end

--- Set the offset directly (page navigation only): a page start can exceed the
--- content_h - viewport_h clamp — when the last page holds less than one
--- viewport, its start is near content_h, and going through scrollBy would
--- clamp it to max_offset, showing a shifted duplicate of the previous page.
function ScrollContainer:_setOffset(new_offset)
    new_offset = math.max(0, new_offset)
    if new_offset ~= self.scroll_offset then
        self.scroll_offset = new_offset
        self:_updateScrollBar()
        if self.dialog then
            UIManager:setDirty(self.dialog, function()
                return "partial", self.dimen
            end)
        end
    end
end

function ScrollContainer:scrollToRatio(ratio)
    ratio = math.max(0, math.min(1, ratio))
    local pages = self.pages
    if not pages or #pages == 0 then return end
    local target = math.min(#pages, math.max(1, math.floor(ratio * #pages) + 1))
    self:_setOffset(pages[target])
end

function ScrollContainer:onScrollText(arg, ges)
    -- swipe north (up) = forward, south (down) = backward
    if ges.direction == "north" then
        self:scrollToPage(1)
        return true
    elseif ges.direction == "south" then
        self:scrollToPage(-1)
        return true
    end
    -- west/east: propagate outward (closes the popup)
    return false
end

--- Tap left half to page up, right half to page down (mirrored UI flips).
function ScrollContainer:onTapScrollText(arg, ges)
    if BD.flipIfMirroredUILayout(ges.pos.x < Screen:getWidth() / 2) then
        self:scrollToPage(-1)
    else
        self:scrollToPage(1)
    end
    return true
end

function ScrollContainer:onScrollUp()
    self:scrollToPage(-1)
    return true
end

function ScrollContainer:onScrollDown()
    self:scrollToPage(1)
    return true
end

-- Continuous scroll: remember the pan start, scroll by relative movement on
-- release (same pattern as ScrollTextWidget).
function ScrollContainer:onPanText(arg, ges)
    self._pan_direction = ges.direction
    self._pan_relative_x = ges.relative.x
    self._pan_relative_y = ges.relative.y
    return true
end

function ScrollContainer:onPanReleaseText(arg, ges)
    if self._pan_direction and self._pan_relative_y then
        if self._pan_direction == "north" or self._pan_direction == "south" then
            self:scrollBy(-self._pan_relative_y)
        end
        self._pan_direction = nil
        self._pan_relative_x = nil
        self._pan_relative_y = nil
        return true
    end
    return false
end

function ScrollContainer:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y

    if self.viewport_h > 0 and self.page_bb_getter then
        local cur = self:_currentPageIndex()
        local page_bb = self.page_bb_getter(cur)
        if page_bb then
            local visible_h = math.min(self.viewport_h, page_bb:getHeight())
            if visible_h > 0 then
                bb:blitFrom(page_bb, x + self.margin_left, y,
                    0, 0, self.text_w, visible_h)
            end
        end
    end

    if self.v_scroll_bar then
        -- scrollbar hugs the screen right edge (10 px slack)
        local bar_x = x + Screen:getWidth() - self.scrollbar_w - 10
        self.v_scroll_bar:paintTo(bb, bar_x, y)
    end
end

-- Release only this component's references; page bitmaps are owned by the
-- widget's cache.
function ScrollContainer:free()
    self.page_bb_getter = nil
end

return ScrollContainer
