-- Full-screen, e-ink-friendly bookshelf with direct Books/Public Accounts tabs.

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
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local FocusNav = require("weread.ui.focus_nav")
local I18n = require("weread.lib.i18n")
local T = require("ffi/util").template

local function _(text) return I18n.tr(text) end

local ShelfRow = InputContainer:extend{
    text = "",
    status = "",
    width = nil,
    font_size = 22,
    callback = nil,
    show_parent = nil,
}

function ShelfRow:init()
    local padding = Size.padding.large
    local inner_width = self.width - 2 * padding
    local face = Font:getFace("cfont", self.font_size)
    local status_widget = TextWidget:new{ text = self.status or "", face = face }
    local status_width = status_widget:getSize().w
    local gap = Size.padding.large
    local title_widget = TextWidget:new{
        text = self.text,
        face = face,
        max_width = math.max(1, inner_width - status_width - gap),
    }
    gap = math.max(gap, inner_width - title_widget:getSize().w - status_width)
    self.frame = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding_left = padding,
        padding_right = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.large,
        background = Blitbuffer.COLOR_WHITE,
        show_parent = self.show_parent,
        HorizontalGroup:new{
            align = "center",
            title_widget,
            HorizontalSpan:new{ width = gap },
            status_widget,
        },
    }
    self[1] = self.frame
    self.dimen = self.frame:getSize()
    self.ges_events = {
        TapShelfRow = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function ShelfRow:onTapShelfRow()
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

function ShelfRow:onFocus()
    self.frame.invert = true
    return true
end

function ShelfRow:onUnfocus()
    self.frame.invert = false
    return true
end

local LibraryView = FocusManager:extend{
    mode = "books",
    title = nil,
    wp_enable = true,
    books = nil,
    accounts = nil,
    keyword = nil,
    sort_label = nil,
    filter_label = nil,
    on_switch = nil,
    on_search = nil,
    on_refresh = nil,
    on_sort = nil,
    on_filter = nil,
    on_select = nil,
}

function LibraryView:tabBar()
    local tabs = {
        { mode = "books", text = T(_("Books (%1)"), #(self.books or {})) },
        { mode = "public_account", text = T(_("Public Accounts (%1)"), #(self.accounts or {})) },
    }
    local cell_w = math.floor(self.screen_w / #tabs)
    local row = HorizontalGroup:new{}
    self._tab_buttons = {}
    for index, tab in ipairs(tabs) do
        local active = tab.mode == self.mode
        local enabled = tab.mode ~= "public_account" or self.wp_enable
        local width = index == #tabs and self.screen_w - cell_w or cell_w
        local button = Button:new{
            text = tab.text,
            width = width,
            radius = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            text_font_size = 24,
            text_font_bold = true,
            enabled = enabled,
            show_parent = self,
            callback = function()
                if enabled and not active and self.on_switch then
                    self.on_switch(tab.mode)
                end
            end,
        }
        if enabled then self._tab_buttons[#self._tab_buttons + 1] = button end
        table.insert(row, VerticalGroup:new{
            align = "left",
            button,
            LineWidget:new{
                dimen = Geom:new{ w = width, h = active and Screen:scaleBySize(3) or 1 },
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
        })
    end
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, row }
end

function LibraryView:actionBar()
    local cell_w = math.floor(self.screen_w / 2)
    local search_label = self.keyword and self.keyword ~= ""
        and T(_("⌕ Search: %1"), self.keyword) or _("⌕ Search shelf")
    local filter_label = self.filter_label and self.filter_label ~= _("All")
        and T(_("▾ Filter: %1"), self.filter_label) or _("▾ Filter")
    local sort_label = self.sort_label and self.sort_label ~= ""
        and T(_("⇅ Sort: %1"), self.sort_label) or _("⇅ Sort")
    local search_button = Button:new{
        text = search_label,
        width = cell_w,
        radius = 0, margin = 0, bordersize = 0,
        text_font_bold = false,
        show_parent = self,
        callback = function() if self.on_search then self.on_search() end end,
    }
    local refresh_button = Button:new{
        text = _("↻ Get latest"),
        width = self.screen_w - cell_w,
        radius = 0, margin = 0, bordersize = 0,
        text_font_bold = false,
        show_parent = self,
        callback = function() if self.on_refresh then self.on_refresh() end end,
    }
    local primary = HorizontalGroup:new{ search_button, refresh_button }
    local sort_button = Button:new{
            text = sort_label,
            width = self.mode == "books" and cell_w or self.screen_w,
            radius = 0, margin = 0, bordersize = 0,
            text_font_bold = false,
            show_parent = self,
            callback = function() if self.on_sort then self.on_sort() end end,
        }
    local secondary = HorizontalGroup:new{ sort_button }
    local filter_button
    if self.mode == "books" then
        filter_button = Button:new{
            text = filter_label,
            width = self.screen_w - cell_w,
            radius = 0, margin = 0, bordersize = 0,
            text_font_bold = false,
            show_parent = self,
            callback = function() if self.on_filter then self.on_filter() end end,
        }
        table.insert(secondary, filter_button)
    end
    self._action_secondary = { sort_button }
    if filter_button then self._action_secondary[#self._action_secondary + 1] = filter_button end
    self._action_primary = { search_button, refresh_button }
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{ align = "left", secondary, primary },
    }
end

function LibraryView:itemStatus(book)
    if self.mode == "public_account" then return book.author or "" end
    local status = ""
    if book.readUpdateTime and book.readUpdateTime > 0 then
        status = os.date("%Y-%m-%d", book.readUpdateTime)
    elseif book.finishReading == 1 then
        status = _("Done")
    end
    if book._cached then
        status = status ~= "" and ("✓  " .. status) or "✓"
    end
    return status
end

function LibraryView:content()
    local source = self.mode == "public_account"
        and (self.accounts or {}) or (self.books or {})
    local content = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = self.list_width },
    }
    self._item_rows = {}
    if #source == 0 then
        table.insert(content, VerticalSpan:new{ width = Size.padding.large })
        table.insert(content, TextWidget:new{
            text = self.keyword and self.keyword ~= "" and _("No shelf matches.") or _("No items."),
            max_width = self.content_width,
        })
        return content
    end
    for _i, book in ipairs(source) do
        local shelf_row = ShelfRow:new{
            text = book.title or book.bookId or book.book_id or _("Untitled"),
            status = self:itemStatus(book),
            width = self.list_width,
            font_size = self.mode == "books" and 20 or 22,
            show_parent = self,
            callback = function()
                if self.on_select then self.on_select(book, self.mode) end
            end,
        }
        self._item_rows[#self._item_rows + 1] = shelf_row
        table.insert(content, shelf_row)
        table.insert(content, HorizontalGroup:new{
            HorizontalSpan:new{ width = Size.padding.large },
            LineWidget:new{
                dimen = Geom:new{ w = self.list_width - 2 * Size.padding.large, h = 1 },
                background = Blitbuffer.COLOR_GRAY,
            },
        })
    end
    return content
end

function LibraryView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.covers_fullscreen = true
    self.outer_margin = 0
    self.content_width = self.screen_w
    self.list_width = self.screen_w - 3 * Screen:scaleBySize(6)
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end

    self.title_bar = TitleBar:new{
        width = self.screen_w,
        title = self.title or _("WeRead Bookshelf"),
        title_face = Font:getFace("tfont", 28),
        align = "center",
        with_bottom_line = true,
        right_icon_size_ratio = 0.75,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local tabs = self:tabBar()
    local actions = self:actionBar()
    local scroll_h = self.screen_h - self.title_bar:getHeight()
        - tabs:getSize().h - actions:getSize().h
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = scroll_h },
        show_parent = self,
        VerticalGroup:new{ align = "left", self:content() },
    }
    local rows = {
        self._tab_buttons,
        self._action_secondary,
        self._action_primary,
    }
    for _i, item_row in ipairs(self._item_rows) do
        rows[#rows + 1] = { item_row }
    end
    local outside_scroll = {}
    for _i, button in ipairs(self._tab_buttons) do outside_scroll[button] = true end
    for _i, button in ipairs(self._action_secondary) do outside_scroll[button] = true end
    for _i, button in ipairs(self._action_primary) do outside_scroll[button] = true end
    FocusNav.apply(self, rows, { scroll = scroll, outside_scroll = outside_scroll })
    -- Items follow the three fixed rows (tabs, secondary, primary actions).
    FocusNav.initialFocus(self, 1, #rows > 3 and 4 or 1)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", self.title_bar, tabs, actions, scroll },
    }
end

function LibraryView:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function LibraryView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function LibraryView:onClose()
    UIManager:close(self)
    return true
end

local M = {}
function M.show(data, callbacks)
    callbacks = callbacks or {}
    local view = LibraryView:new{
        mode = data.mode,
        title = data.title,
        wp_enable = data.wp_enable ~= false,
        books = data.books,
        accounts = data.accounts,
        keyword = data.keyword,
        sort_label = data.sort_label,
        filter_label = data.filter_label,
        on_switch = callbacks.on_switch,
        on_search = callbacks.on_search,
        on_refresh = callbacks.on_refresh,
        on_sort = callbacks.on_sort,
        on_filter = callbacks.on_filter,
        on_select = callbacks.on_select,
    }
    UIManager:show(view)
    return view
end

return M
