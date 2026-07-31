-- Structured, offline-first book detail page.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local I18n = require("weread.lib.i18n")

local function _(text) return I18n.tr(text) end

local RefreshRow = InputContainer:extend{
    label = "",
    date = "",
    width = nil,
    callback = nil,
    show_parent = nil,
    label_bold = true,
    bordersize = Size.border.thin,
    padding_left = nil,
    padding_right = nil,
}

function RefreshRow:init()
    local padding_left = self.padding_left == nil and Size.padding.large or self.padding_left
    local padding_right = self.padding_right == nil and Size.padding.large or self.padding_right
    local inner_width = self.width - padding_left - padding_right - 2 * self.bordersize
    local left = TextWidget:new{
        text = self.label,
        face = Font:getFace("cfont", 20),
        bold = self.label_bold,
    }
    local right = TextWidget:new{
        text = self.date,
        face = Font:getFace("cfont", 16),
    }
    local gap = math.max(Size.padding.large,
        inner_width - left:getSize().w - right:getSize().w)
    self.frame = FrameContainer:new{
        bordersize = self.bordersize,
        radius = 0,
        margin = 0,
        padding_left = padding_left,
        padding_right = padding_right,
        padding_top = Size.padding.default,
        padding_bottom = Size.padding.default,
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
        TapRefreshRow = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function RefreshRow:onTapRefreshRow()
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

local BookDetailView = InputContainer:extend{
    data = nil,
    on_refresh = nil,
}

function BookDetailView:sectionTitle(text)
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = text,
            face = Font:getFace("tfont", 20),
            bold = true,
            max_width = self.content_width,
        },
        VerticalSpan:new{ width = Size.padding.small },
        LineWidget:new{
            dimen = Geom:new{ w = self.content_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_GRAY,
        },
        VerticalSpan:new{ width = Size.padding.default },
    }
end

function BookDetailView:metadataBlock()
    local group = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.content_width },
    }
    for _i, item in ipairs(self.data.metadata or {}) do
        if item.left or item.right then
            local face = Font:getFace("cfont", 18)
            local half = math.floor((self.content_width - Size.padding.large) / 2)
            local left = TextWidget:new{
                text = item.left or "", face = face, max_width = half,
            }
            local right = TextWidget:new{
                text = item.right or "", face = face, max_width = half,
            }
            local gap = math.max(Size.padding.large,
                self.content_width - left:getSize().w - right:getSize().w)
            table.insert(group, HorizontalGroup:new{
                left,
                HorizontalSpan:new{ width = gap },
                right,
            })
        else
            table.insert(group, TextBoxWidget:new{
                text = item.text or (item.label .. "  " .. item.value),
                face = Font:getFace("cfont", 18),
                width = self.content_width,
            })
        end
        table.insert(group, VerticalSpan:new{ width = Size.padding.small })
    end
    return group
end

function BookDetailView:actionBlock(actions)
    local group = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.content_width },
    }
    for _i, action in ipairs(actions or {}) do
        if action.status then
            table.insert(group, RefreshRow:new{
                label = action.text,
                date = action.status,
                width = self.content_width,
                label_bold = action.bold == true,
                bordersize = 0,
                padding_left = 0,
                padding_right = 0,
                show_parent = self,
                callback = action.callback,
            })
        else
            table.insert(group, Button:new{
                text = action.text,
                width = self.content_width,
                height = Screen:scaleBySize(54),
                align = "left",
                radius = 0,
                margin = 0,
                padding_h = Size.padding.large,
                bordersize = 0,
                text_font_size = 20,
                text_font_bold = action.bold == true,
                enabled = action.enabled ~= false,
                show_parent = self,
                callback = action.callback,
            })
        end
        table.insert(group, LineWidget:new{
            dimen = Geom:new{ w = self.content_width, h = 1 },
            background = Blitbuffer.COLOR_GRAY,
        })
    end
    return group
end

function BookDetailView:footer()
    local actions = self.data.bottom_actions or {}
    local count = math.max(1, #actions)
    local cell_width = math.floor(self.screen_w / count)
    local row = HorizontalGroup:new{}
    for index, action in ipairs(actions) do
        table.insert(row, Button:new{
            text = action.text,
            width = index == count
                and self.screen_w - cell_width * (count - 1) or cell_width,
            height = Screen:scaleBySize(52),
            radius = 0,
            margin = 0,
            bordersize = Size.border.thin,
            text_font_size = 21,
            text_font_bold = true,
            enabled = action.enabled ~= false,
            show_parent = self,
            callback = action.callback,
        })
    end
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, row }
end

function BookDetailView:content()
    local data = self.data
    local content = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.content_width },
    }
    if data.author_line and data.author_line ~= "" then
        table.insert(content, TextBoxWidget:new{
            text = data.author_line,
            face = Font:getFace("cfont", 19),
            width = self.content_width,
            alignment = "center",
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
    end
    if data.status_line and data.status_line ~= "" then
        table.insert(content, TextBoxWidget:new{
            text = data.status_line,
            face = Font:getFace("cfont", 17),
            bold = true,
            width = self.content_width,
            alignment = "center",
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
    end

    table.insert(content, RefreshRow:new{
        label = data.refresh_label,
        date = data.refresh_date,
        width = self.content_width,
        show_parent = self,
        callback = function() if self.on_refresh then self.on_refresh() end end,
    })
    table.insert(content, VerticalSpan:new{ width = Size.padding.large })

    if data.chapter_action then
        table.insert(content, self:actionBlock({ data.chapter_action }))
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
    end

    if #(data.metadata or {}) > 0 then
        table.insert(content, self:sectionTitle(_("Book information")))
        table.insert(content, self:metadataBlock())
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
    end
    if data.intro and data.intro ~= "" then
        table.insert(content, self:sectionTitle(_("Introduction")))
        table.insert(content, TextBoxWidget:new{
            text = data.intro,
            face = Font:getFace("cfont", 17),
            width = self.content_width,
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
    end
    if data.review_action then
        table.insert(content, self:sectionTitle(_("Book reviews")))
        table.insert(content, self:actionBlock({ data.review_action }))
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
    end
    if #(data.actions or {}) > 0 then
        table.insert(content, self:sectionTitle(_("More actions")))
        table.insert(content, self:actionBlock(data.actions))
    end
    return content
end

function BookDetailView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true
    self.outer_margin = Size.padding.large
    self.content_width = self.screen_w - 2 * self.outer_margin
        - 3 * Screen:scaleBySize(6)
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.data.title or _("Book details"),
        title_face = Font:getFace("tfont", 28),
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local footer = self:footer()
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{
            w = self.screen_w,
            h = self.screen_h - self.title_bar:getHeight() - footer:getSize().h,
        },
        show_parent = self,
        HorizontalGroup:new{
            HorizontalSpan:new{ width = self.outer_margin },
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = self.outer_margin },
                self:content(),
                VerticalSpan:new{ width = self.outer_margin },
            },
        },
    }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", self.title_bar, scroll, footer },
    }
end

function BookDetailView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function BookDetailView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function BookDetailView:onClose()
    UIManager:close(self)
    return true
end

local M = {}
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = BookDetailView:new{
        data = data,
        on_refresh = callbacks.on_refresh,
    }
    UIManager:show(view)
    return view
end

return M
