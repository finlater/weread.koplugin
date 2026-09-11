-- Paginated native widgets: at most one screen of catalog rows is allocated.
local BB = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local FocusNav = require("weread.ui.focus_nav")
local PluginUtil = require("weread.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local Screen = Device.screen
local Picker = FocusManager:extend{ page = 1 }

function Picker:button(text, width, callback, options)
    local args = { text = text, width = width, callback = callback,
        height = self.row_height, bordersize = 0, padding = 0, margin = 0,
        text_font_size = 20, text_font_bold = false,
        avoid_text_truncation = false, show_parent = self }
    for key, value in pairs(options or {}) do args[key] = value end
    return Button:new(args)
end

function Picker:line()
    return LineWidget:new{
        dimen = Geom:new{ w = self.width, h = self.line_height }, background = BB.COLOR_LIGHT_GRAY,
    }
end

function Picker:actionBar()
    local bar = ButtonTable:new{
        width = self.width, zero_sep = true, show_parent = self,
        buttons = { {
            { text = _("Clear selection"), enabled = self.model.count > 0,
                callback = function() self.model:clear(); self:rebuild() end },
            { text = T(_("Match (%1)"), self.model.count), enabled = self.model.count > 0,
                callback = function()
                    local chapters = self.model:selection()
                    if #chapters == 0 then return end
                    self:onClose()
                    self.on_select(chapters)
                end },
        } },
    }
    -- The outer focus manager owns all rows, including the native action bar.
    bar.key_events, bar.layout = {}, nil
    return bar
end

function Picker:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.row_height, self.line_height = Screen:scaleBySize(52), math.max(1, Screen:scaleBySize(1))
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.covers_fullscreen = true
    self.title_bar = TitleBar:new{
        width = self.width, title = _("Choose chapters to match"),
        subtitle = self.book_title, title_face = Font:getFace("tfont", 24),
        with_bottom_line = true, show_parent = self,
        close_callback = function() self:onClose() end,
    }
    self.hint = FrameContainer:new{
        padding = Screen:scaleBySize(10), margin = 0, bordersize = 0,
        TextWidget:new{ text = _("Arrows expand. Selecting a parent selects its chapters."),
            face = Font:getFace("cfont", 14), fgcolor = BB.COLOR_DARK_GRAY,
            max_width = self.width - Screen:scaleBySize(20) },
    }
    self.actions = self:actionBar()
    local available = self.height - self.title_bar:getHeight() - self.hint:getSize().h
        - self.row_height - self.line_height - self.actions:getSize().h
    self.per_page = math.max(1, math.floor(available / (self.row_height + self.line_height)))
    self.list_height = available
    for index, node in ipairs(self.model:visible()) do
        if node == self.model.current then self.page = math.ceil(index / self.per_page); break end
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    self:rebuild()
end

function Picker:rebuild(focus_node, focus_column)
    -- The title and hint are reused; free all previous page widgets before
    -- allocating new ones. No hidden chapter owns a font/gesture/widget tree.
    if self.body then
        self.body:free()
        self.actions = self:actionBar()
    end
    local visible = self.model:visible()
    self.pages = math.max(1, math.ceil(#visible / self.per_page))
    self.page = math.max(1, math.min(self.page, self.pages))
    local list, focus_rows = VerticalGroup:new{ align = "left" }, {}
    local side = Screen:scaleBySize(40)
    local focus_y = 1
    for index = (self.page - 1) * self.per_page + 1, math.min(#visible, self.page * self.per_page) do
        local node = visible[index]
        local indent = math.min(node.depth, 5) * Screen:scaleBySize(14)
        local branch = node.last > node.index
        local arrow = self:button(branch and (node.expanded and "▾" or "▸") or "", side,
            function() self.model:expand(node); self:rebuild(node, 1) end, { enabled = branch })
        local toggle = function() self.model:toggle(node); self:rebuild(node, 2) end
        local matched = node.total == 0
        local status_width = matched and Screen:scaleBySize(62) or 0
        local title = self:button(node.title or "", self.width - indent - 2 * side - status_width,
            toggle, { align = "left", text_font_bold = branch or node == self.model.current, enabled = not matched })
        local mark = matched and "" or node.count == node.total and "✓" or node.count > 0 and "−" or "□"
        local check = self:button(mark, side, toggle, { text_font_size = 24, enabled = not matched })
        local row = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = indent }, arrow, title }
        if matched then
            row[#row + 1] = self:button(_("Matched"), status_width, nil, { text_font_size = 13, enabled = false })
        end
        row[#row + 1] = check
        list[#list + 1], list[#list + 2] = row, self:line()
        focus_rows[#focus_rows + 1] = { arrow, title, check }
        if node == focus_node then focus_y = #focus_rows end
    end
    list[#list + 1] = VerticalSpan:new{ width = math.max(0, self.list_height - list:getSize().h) }
    -- getSize() caches offsets for the rows above. The appended spacer needs
    -- its own offset before the first paint (and after every page rebuild).
    list:resetLayout()
    local third = math.floor(self.width / 3)
    local previous = self:button("‹", third, function() self:onPrevPage() end, { enabled = self.page > 1 })
    local counter = self:button(tostring(self.page) .. " / " .. tostring(self.pages), third, nil, { enabled = false })
    local next_page = self:button("›", self.width - third * 2, function() self:onNextPage() end,
        { enabled = self.page < self.pages })
    focus_rows[#focus_rows + 1] = { previous, counter, next_page }
    focus_rows[#focus_rows + 1] = self.actions.buttons_layout[1]
    self.layout = focus_rows
    self.body = VerticalGroup:new{ align = "left", list, self:line(),
        HorizontalGroup:new{ previous, counter, next_page }, self.actions }
    self[1] = FrameContainer:new{
        background = BB.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{ align = "left", self.title_bar, self.hint, self.body },
    }
    FocusNav.initialFocus(self, focus_column or 2, focus_y)
    UIManager:setDirty(self, "ui")
end

function Picker:onNextPage()
    if self.page < self.pages then self.page = self.page + 1; self:rebuild() end
    return true
end

function Picker:onPrevPage()
    if self.page > 1 then self.page = self.page - 1; self:rebuild() end
    return true
end

function Picker:onSwipe(_, ges)
    if ges.direction == "west" then return self:onNextPage() end
    if ges.direction == "east" then return self:onPrevPage() end
    return true
end

function Picker:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function Picker:onClose()
    UIManager:close(self)
    return true
end

function Picker:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

local M = {}
function M.show(options)
    local picker = Picker:new(options)
    UIManager:show(picker)
    return picker
end
return M
