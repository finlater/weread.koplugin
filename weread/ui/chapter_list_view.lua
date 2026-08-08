-- Chapter catalog styled consistently with the book detail page.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")

local function _(text) return I18n.tr(text) end

local ChapterRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    callback = nil,
    show_parent = nil,
}

function ChapterRow:init()
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", 20)
    local right = TextWidget:new{ text = self.status, face = face }
    local right_width = right:getSize().w
    local gap = Size.padding.large
    local left = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - right_width - gap),
    }
    gap = math.max(gap, inner_width - left:getSize().w - right_width)
    self.frame = FrameContainer:new{
        bordersize = 0, radius = 0, margin = 0,
        padding_left = padding, padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            left,
            HorizontalSpan:new{ width = gap },
            right,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapChapterRow = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function ChapterRow:onTapChapterRow()
    if not self.callback then return true end
    self.frame.invert = true
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:forceRePaint()
    self.frame.invert = false
    UIManager:widgetRepaint(self.frame, self.frame.dimen.x, self.frame.dimen.y)
    UIManager:setDirty(nil, "fast", self.frame.dimen)
    self.callback()
    return true
end

function ChapterRow:onFocus()
    self.frame.invert = true
    return true
end

function ChapterRow:onUnfocus()
    self.frame.invert = false
    return true
end

local ChapterListView = FocusManager:extend{
    title = nil,
    chapters = nil,
    on_refresh = nil,
    on_select_download = nil,
    on_select = nil,
    on_close = nil,
}

function ChapterListView:toolbar()
    local half = math.floor(self.screen_w / 2)
    local refresh_button = Button:new{
        text = _("↻ Refresh chapter list"),
        width = half,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 19,
        text_font_bold = false,
        show_parent = self,
        callback = function() if self.on_refresh then self.on_refresh() end end,
    }
    local select_button = Button:new{
        text = _("✓ Select chapters to download"),
        width = self.screen_w - half,
        radius = 0, margin = 0,
        bordersize = Size.border.thin,
        text_font_size = 19,
        text_font_bold = false,
        show_parent = self,
        callback = function()
            if self.on_select_download then self.on_select_download() end
        end,
    }
    self._toolbar_buttons = { refresh_button, select_button }
    return HorizontalGroup:new{ refresh_button, select_button }
end

function ChapterListView:content()
    local group = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.list_width },
    }
    self._chapter_rows = {}
    for _i, chapter in ipairs(self.chapters or {}) do
        local row = ChapterRow:new{
            text = chapter.title,
            status = chapter.status,
            width = self.list_width,
            show_parent = self,
            callback = function()
                if self.on_select then self.on_select(chapter.source) end
            end,
        }
        self._chapter_rows[#self._chapter_rows + 1] = row
        table.insert(group, row)
        table.insert(group, HorizontalGroup:new{
            HorizontalSpan:new{ width = Size.padding.large },
            LineWidget:new{
                dimen = Geom:new{ w = self.list_width - 2 * Size.padding.large, h = 1 },
                background = Blitbuffer.COLOR_GRAY,
            },
        })
    end
    return group
end

function ChapterListView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    self.covers_fullscreen = true
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or _("Chapter list"),
        title_face = Font:getFace("tfont", 28),
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local toolbar = self:toolbar()
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.screen_w,
            h = self.screen_h - self.title_bar:getHeight() - toolbar:getSize().h,
        },
        show_parent = self,
        self:content(),
    }
    local rows = { self._toolbar_buttons }
    for _i, chapter_row in ipairs(self._chapter_rows) do
        rows[#rows + 1] = { chapter_row }
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._toolbar_buttons) do outside_scroll[button] = true end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    -- Chapters follow the toolbar row.
    FocusNav.initialFocus(self, 1, #rows > 1 and 2 or 1)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", self.title_bar, toolbar, scroll },
    }
end

function ChapterListView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function ChapterListView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function ChapterListView:onClose()
    UIManager:close(self)
    if self.on_close then
        UIManager:scheduleIn(0.1, self.on_close)
    end
    return true
end

local M = {}
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = ChapterListView:new{
        title = data.title,
        chapters = data.chapters,
        on_refresh = callbacks.on_refresh,
        on_select_download = callbacks.on_select_download,
        on_select = callbacks.on_select,
        on_close = callbacks.on_close,
    }
    UIManager:show(view)
    return view
end

return M
