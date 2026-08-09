-- Full-screen, e-ink-friendly book review list with Recommended / Latest tabs.
-- This is a presentation-only widget; network loading is handled by main.lua.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local T = require("ffi/util").template

local BookReviews = require("weread.lib.book_reviews")
local I18n = require("weread.lib.i18n")

local function _(text)
    return I18n.tr(text)
end

local TABS = {
    { mode = "recommended", text = "Recommended reviews" },
    { mode = "latest", text = "Latest reviews" },
}

local BookReviewsView = FocusManager:extend{
    book_title = nil,
    mode = "recommended",
    result = nil,
    on_switch = nil,
    on_select = nil,
}

function BookReviewsView:buildTabBar()
    local first_width = math.floor(self.screen_w / #TABS)
    local row = HorizontalGroup:new{}
    self._tab_buttons = {}
    for index, tab in ipairs(TABS) do
        local active = tab.mode == self.mode
        local button = Button:new{
            text = _(tab.text),
            width = index == #TABS
                and self.screen_w - first_width * (#TABS - 1)
                or first_width,
            radius = 0,
            margin = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            preselect = active,
            text_font_bold = active,
            show_parent = self,
            callback = function()
                if not active and self.on_switch then
                    self.on_switch(tab.mode)
                end
            end,
        }
        self._tab_buttons[#self._tab_buttons + 1] = button
        if active then
            -- Preselect is painted as an inverted frame; without this the
            -- focus cursor leaving the tab would erase its highlight.
            button.onUnfocus = function(_self)
                _self.frame.invert = true
                return true
            end
        end
        table.insert(row, button)
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        row,
    }
end

function BookReviewsView:reviewText(review)
    local metadata = {
        review.author ~= "" and review.author or _("Anonymous"),
    }
    if review.rating > 0 then
        metadata[#metadata + 1] = T(_("Score %1"), BookReviews.format_rating(review.rating))
    end
    local review_date = BookReviews.format_date(review.create_time)
    if review_date ~= "" then
        metadata[#metadata + 1] = review_date
    end
    local preview = BookReviews.preview(
        review.content ~= "" and review.content or _("No review content."), 80
    )
    return table.concat(metadata, " · ") .. "  |  " .. preview
end

function BookReviewsView:buildContent()
    local content = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.content_width },
    }
    self._review_buttons = {}
    local items = self.result and self.result.items or {}
    if #items == 0 then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = _("No reviews."),
            face = Font:getFace("cfont", 18),
            max_width = self.content_width,
        })
        return content
    end

    for _i, review in ipairs(items) do
        local button = Button:new{
            text = self:reviewText(review),
            width = self.content_width,
            height = Screen:scaleBySize(66),
            align = "left",
            radius = 0,
            margin = 0,
            padding_h = Size.padding.large,
            padding_v = Size.padding.default,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            text_font_bold = false,
            text_font_size = 18,
            show_parent = self,
            callback = function()
                if self.on_select then
                    self.on_select(review, self.mode)
                end
            end,
        }
        self._review_buttons[#self._review_buttons + 1] = button
        table.insert(content, button)
        table.insert(content, VerticalSpan:new{ width = Size.padding.small })
    end
    return content
end

function BookReviewsView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true
    self.outer_margin = Size.padding.large
    local scrollbar_reserve = 3 * Screen:scaleBySize(6)
    self.content_width = self.screen_w - 2 * self.outer_margin - scrollbar_reserve

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = T("%1 · %2", _("Book reviews"), self.book_title or _("Untitled")),
        title_multilines = true,
        align = "center",
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local tab_bar = self:buildTabBar()
    local scroll_height = self.screen_h
        - self.title_bar:getHeight() - tab_bar:getSize().h
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_height },
        show_parent = self,
        HorizontalGroup:new{
            HorizontalSpan:new{ width = self.outer_margin },
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = self.outer_margin },
                self:buildContent(),
                VerticalSpan:new{ width = self.outer_margin },
            },
        },
    }
    local rows = { self._tab_buttons }
    for _i, review_button in ipairs(self._review_buttons) do
        rows[#rows + 1] = { review_button }
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._tab_buttons) do outside_scroll[button] = true end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    -- Reviews follow the tab row.
    FocusNav.initialFocus(self, 1, #rows > 1 and 2 or 1)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", self.title_bar, tab_bar, scroll },
    }
end

function BookReviewsView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function BookReviewsView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function BookReviewsView:onClose()
    UIManager:close(self)
    return true
end

local M = {}

function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = BookReviewsView:new{
        book_title = data.book_title,
        mode = data.mode,
        result = data.result,
        on_switch = callbacks.on_switch,
        on_select = callbacks.on_select,
    }
    UIManager:show(view)
    return view
end

return M
