local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local time = require("ui/time")
local Screen = Device.screen

local DownloadDialog = InputContainer:extend{
    title = "",
    description = nil,
    progress_max = 100,
    buttons = nil,
    refresh_time_seconds = 3,
}

function DownloadDialog:init()
    self.dimen = Screen:getSize()
    self.last_redraw_time_ms = 0

    local width = Screen:getWidth() - Screen:scaleBySize(80)

    local vertical_group = VerticalGroup:new{}

    self.title_widget = TextWidget:new{
        text = self.title or "",
        face = Font:getFace("ffont"),
        bold = true,
        max_width = width,
    }
    self.title_container = CenterContainer:new{
        dimen = Geom:new{
            w = width,
            h = self.title_widget:getSize().h,
        },
        self.title_widget,
    }
    table.insert(vertical_group, self.title_container)

    if self.description and self.description ~= "" then
        self.description_widget = TextWidget:new{
            text = self.description,
            face = Font:getFace("xx_smallinfofont"),
            max_width = width,
        }
        self.description_container = CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = self.description_widget:getSize().h,
            },
            self.description_widget,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(vertical_group, self.description_container)
    end

    if self.progress_max and self.progress_max > 0 then
        self.progress_bar = ProgressWidget:new{
            fillcolor = Blitbuffer.COLOR_BLACK,
            width = width,
            height = Screen:scaleBySize(18),
            padding = Size.padding.large,
            margin = Size.margin.tiny,
            percentage = 0,
        }
        table.insert(vertical_group, self.progress_bar)
    end

    if self.buttons then
        local button_table = ButtonTable:new{
            width = width,
            buttons = self.buttons,
            zero_sep = true,
            show_parent = self,
        }
        table.insert(vertical_group, VerticalSpan:new{ width = Size.padding.large })
        table.insert(vertical_group, button_table)
    end

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = Size.padding.large,
            padding_bottom = self.buttons and 0 or nil,
            background = Blitbuffer.COLOR_WHITE,
            vertical_group,
        },
    }
end

function DownloadDialog:reportProgress(progress)
    if not self.progress_bar then return end
    self.progress_bar:setPercentage(progress / self.progress_max)
    local now = time.now()
    local elapsed = now - self.last_redraw_time_ms
    if self.progress_bar.percentage >= 1 or elapsed >= self.refresh_time_seconds * 1000 * 1000 then
        self.last_redraw_time_ms = now
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:setTitle(title)
    title = title or ""
    if self.title == title then return end
    self.title = title
    if self.title_widget and self.title_widget.setText then
        self.title_widget:setText(self.title)
        UIManager:setDirty(self, function() return "fast", self.dimen end)
        UIManager:forceRePaint()
    end
end

function DownloadDialog:show()
    UIManager:show(self, "ui")
end

function DownloadDialog:close()
    UIManager:close(self, "ui")
end

return DownloadDialog
