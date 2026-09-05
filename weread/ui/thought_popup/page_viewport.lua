--[[--
Page viewport for the centered thought popup.

Paints the bitmap of the currently selected page into its dimen. There is no
scrolling: the current page is read through page_index_getter() on every
paint, so navigation code only updates the popup page index and the next
repaint shows the new page. The page bitmap itself is produced lazily by
page_bb_getter(page_idx).
--]]

local Widget = require("ui/widget/widget")

local PageViewport = Widget:extend{
    page_index_getter = nil,  -- function() -> current page index
    page_bb_getter = nil,     -- function(page_idx) -> Blitbuffer
    margin_left = 0,
    text_w = 0,
}

function PageViewport:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local page_idx = self.page_index_getter and self.page_index_getter() or 1
    local page_bb = self.page_bb_getter and self.page_bb_getter(page_idx)
    if page_bb then
        local visible_h = math.min(self.dimen.h, page_bb:getHeight())
        if visible_h > 0 then
            bb:blitFrom(page_bb, x + self.margin_left, y, 0, 0, self.text_w, visible_h)
        end
    end
end

return PageViewport
