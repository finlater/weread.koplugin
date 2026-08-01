-- Structured, offline-first book detail page.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
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

local FooterAction = InputContainer:extend{
    text = "",
    subtitle = nil,
    width = nil,
    height = nil,
    enabled = true,
    callback = nil,
    show_parent = nil,
}

function FooterAction:init()
    local color = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    local content = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = self.text,
            face = Font:getFace("cfont", 20),
            bold = true,
            fgcolor = color,
            max_width = self.width - 2 * Size.padding.small,
        },
    }
    if self.subtitle and self.subtitle ~= "" then
        table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(2) })
        table.insert(content, TextWidget:new{
            text = self.subtitle,
            face = Font:getFace("cfont", 13),
            fgcolor = color,
            max_width = self.width - 2 * Size.padding.small,
        })
    end
    self.frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        radius = 0,
        margin = 0,
        padding = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            content,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapFooterAction = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function FooterAction:onTapFooterAction()
    if not self.enabled or not self.callback then return true end
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
            local left = TextBoxWidget:new{
                text = item.left or "",
                face = face,
                width = half,
                alignment = "left",
            }
            local right = TextBoxWidget:new{
                text = item.right or "",
                face = face,
                width = half,
                alignment = "left",
            }
            table.insert(group, HorizontalGroup:new{
                left,
                HorizontalSpan:new{ width = Size.padding.large },
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
    local footer_height = Screen:scaleBySize(66)
    local row = HorizontalGroup:new{}
    for index, action in ipairs(actions) do
        table.insert(row, FooterAction:new{
            text = action.text,
            subtitle = action.subtitle,
            width = index == count
                and self.screen_w - cell_width * (count - 1) or cell_width,
            height = footer_height,
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
    local refresh_width = math.floor(self.content_width * 0.34)
    local summary_width = self.content_width - refresh_width - Size.padding.large
    local summary = VerticalGroup:new{ align = "left" }
    if data.author_line and data.author_line ~= "" then
        table.insert(summary, TextBoxWidget:new{
            text = data.author_line,
            face = Font:getFace("cfont", 19),
            bold = true,
            width = summary_width,
        })
        table.insert(summary, VerticalSpan:new{ width = Size.padding.small })
    end
    if data.status_line and data.status_line ~= "" then
        table.insert(summary, TextBoxWidget:new{
            text = data.status_line,
            face = Font:getFace("cfont", 16),
            width = summary_width,
        })
    end
    local refresh = VerticalGroup:new{
        align = "center",
        Button:new{
            text = data.refresh_label,
            width = refresh_width,
            height = Screen:scaleBySize(38),
            radius = Screen:scaleBySize(7),
            margin = 0,
            bordersize = Size.border.thin,
            text_font_size = 16,
            text_font_bold = false,
            show_parent = self,
            callback = function() if self.on_refresh then self.on_refresh() end end,
        },
        VerticalSpan:new{ width = Size.padding.small },
        TextBoxWidget:new{
            text = _("Last updated") .. " " .. data.refresh_date,
            face = Font:getFace("cfont", 12),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = refresh_width,
            alignment = "center",
        },
    }
    table.insert(content, HorizontalGroup:new{
        align = "center",
        summary,
        HorizontalSpan:new{ width = Size.padding.large },
        refresh,
    })
    table.insert(content, VerticalSpan:new{ width = Size.padding.large })

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
