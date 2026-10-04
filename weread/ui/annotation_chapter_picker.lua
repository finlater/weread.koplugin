-- Paginated native widgets: at most one screen of catalog rows is allocated.
local BB = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
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
    local args = { text = text, width = width,
        -- Rebuilding or closing frees this button. Let native press feedback finish first.
        callback = callback and function()
            UIManager:nextTick(function() if not self._closed then callback() end end)
        end,
        height = self.row_height, bordersize = 0, padding = 0, margin = 0, radius = 0,
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
    local border = self.choices and 0 or self.line_height
    local padding = Screen:scaleBySize(10)
    local label = self.choices and _("Remove this chapter match")
        or T(_("Get thoughts (%1 chapters)"), self.model.count)
    self.action_button = self:button(label, self.width - 2 * padding, function()
        if self.choices then
            if self.on_remove then self.on_remove() end
        else
            local chapters = self.model:selection()
            if #chapters == 0 then return end
            self:onClose()
            self.on_select(chapters)
        end
    end, {
        enabled = self.choices and self.on_remove ~= nil or not self.choices and self.model.count > 0,
        height = Screen:scaleBySize(self.choices and 40 or 64) - 2 * border,
        bordersize = border, text_font_size = self.choices and 16 or 22,
        text_font_bold = not self.choices,
    })
    return FrameContainer:new{
        padding = padding, margin = 0, bordersize = 0, self.action_button,
    }
end

function Picker:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.row_height, self.line_height = Screen:scaleBySize(88), math.max(1, Screen:scaleBySize(1))
    self.page_bar_height = Screen:scaleBySize(54)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.covers_fullscreen = true
    self.title_bar = TitleBar:new{
        width = self.width, title = self.choices and _("Choose WeRead chapter") or _("Choose chapters to match"),
        subtitle = self.book_title, title_face = Font:getFace("tfont", 24),
        with_bottom_line = true, show_parent = self,
        close_callback = function() self:onClose() end,
    }
    local hint = self.choices and VerticalGroup:new{ align = "left",
        TextWidget:new{ text = _("Choose a match for local chapter"), face = Font:getFace("cfont", 14),
            fgcolor = BB.COLOR_DARK_GRAY, max_width = self.width - Screen:scaleBySize(20) },
        VerticalSpan:new{ width = Screen:scaleBySize(5) },
        TextWidget:new{ text = self.local_title, face = Font:getFace("cfont", 20), bold = true,
            max_width = self.width - Screen:scaleBySize(20) },
    } or TextWidget:new{ text = _("Select chapters. Fetching again replaces their saved thoughts."),
        face = Font:getFace("cfont", 14), fgcolor = BB.COLOR_DARK_GRAY,
        max_width = self.width - Screen:scaleBySize(20) }
    self.hint = FrameContainer:new{
        padding = Screen:scaleBySize(10), margin = 0, bordersize = 0,
        background = self.choices and BB.COLOR_GRAY_E or BB.COLOR_WHITE,
        LeftContainer:new{ dimen = Geom:new{
            w = self.width - Screen:scaleBySize(20), h = hint:getSize().h }, hint },
    }
    self.actions = self:actionBar()
    local available = self.height - self.title_bar:getHeight() - self.hint:getSize().h
        - self.page_bar_height - self.line_height - self.actions:getSize().h
    self.per_page = math.max(1, math.floor(available / (self.row_height + self.line_height)))
    self.list_height = available
    for index, node in ipairs(self.choices or self.model:visible()) do
        if self.choices and node.current or not self.choices and node == self.model.current then
            self.page = math.ceil(index / self.per_page); break
        end
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    self:rebuild()
end

function Picker:edit(node)
    if not self.on_edit or not node.xpointer then return end
    self.on_edit(node, function(model)
        local selected = {}
        for _, old in ipairs(self.model.nodes) do
            if old.selected then selected[old.toc_index or old.index] = true end
        end
        for _, new in ipairs(model.nodes) do
            if selected[new.toc_index or new.index] then model:toggle(new) end
        end
        self.model = model
        self:rebuild(model.nodes[node.index], 3)
    end)
end

function Picker:choiceRow(item)
    local side, status_width = Screen:scaleBySize(14), Screen:scaleBySize(108)
    local text_width = self.width - 2 * side - status_width
    local half = math.floor(self.row_height / 2)
    local row = self:button("", self.width, item.callback, { enabled = item.select_enabled })
    local title = TextWidget:new{ text = item.text, face = Font:getFace("cfont", 20),
        bold = item.current, max_width = text_width,
        fgcolor = item.select_enabled and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY }
    local detail = TextWidget:new{ text = item.detail, face = Font:getFace("cfont", 14),
        max_width = text_width, fgcolor = BB.COLOR_DARK_GRAY }
    row.label_widget:free()
    row.label_widget = HorizontalGroup:new{
        HorizontalSpan:new{ width = side },
        VerticalGroup:new{ align = "left",
            LeftContainer:new{ dimen = Geom:new{ w = text_width, h = half }, title },
            LeftContainer:new{ dimen = Geom:new{ w = text_width, h = self.row_height - half }, detail },
        },
        CenterContainer:new{ dimen = Geom:new{ w = status_width, h = self.row_height },
            TextWidget:new{ text = item.status, face = Font:getFace("cfont", 13), bold = item.current,
                max_width = status_width, fgcolor = item.current and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY } },
        HorizontalSpan:new{ width = side },
    }
    row.label_container[1] = row.label_widget
    return row, { row }
end

function Picker:chapterRow(node)
    local side, status_width = Screen:scaleBySize(44), Screen:scaleBySize(92)
    local half = math.floor(self.row_height / 2)
    local indent = math.min(node.depth, 5) * Screen:scaleBySize(14)
    local toggle = function() self.model:toggle(node); self:rebuild(node, 2) end
    local content_width = self.width - side - indent - status_width
    local title = self:button(node.title, content_width, toggle, {
        height = half, align = "left", text_font_bold = node.branch or node == self.model.current,
        enabled = node.selectable })
    local remote = self:button(node.chapter and T(_("Linked WeRead chapter: %1"), node.chapter.title or "")
        or _("No matching chapter selected"), content_width, toggle, {
        height = self.row_height - half, align = "left", text_font_size = 14,
        enabled = node.selectable })
    remote.label_widget.fgcolor = BB.COLOR_DARK_GRAY
    local check = self:button(node.selected and "✓" or "□", side, toggle,
        { text_font_size = 24, enabled = node.selectable })
    local matched = node.state == "matched"
    local status = node.state == "ready_to_fetch" and _("Ready to fetch")
        or node.state == "ready_to_match" and _("Ready to match")
        or matched and "✓ " .. _("Matched") or _("Unlinked")
    local border = node.chapter and not matched and self.line_height or 0
    local padding = Screen:scaleBySize(3)
    local label = CenterContainer:new{ dimen = Geom:new{ w = status_width, h = half },
        FrameContainer:new{ bordersize = border, color = BB.COLOR_GRAY, margin = 0, padding = padding,
            background = matched and BB.COLOR_BLACK or BB.COLOR_WHITE,
            TextWidget:new{ text = status, face = Font:getFace("cfont", 13), bold = matched,
                max_width = status_width - 2 * (padding + border),
                fgcolor = matched and BB.COLOR_WHITE or BB.COLOR_DARK_GRAY } } }
    local edit = self:button(node.chapter and _("Change match") or _("Select match"), status_width,
        function() self:edit(node) end, { height = self.row_height - half, text_font_size = 16,
            enabled = self.on_edit ~= nil and node.xpointer ~= nil })
    return HorizontalGroup:new{ align = "center", check, HorizontalSpan:new{ width = indent },
        VerticalGroup:new{ align = "left", title, remote },
        VerticalGroup:new{ align = "center", label, edit } }, { check, title, edit }
end

function Picker:rebuild(focus_node, focus_column)
    -- The title and hint are reused; free all previous page widgets before
    -- allocating new ones. No hidden chapter owns a font/gesture/widget tree.
    if self.body then
        self.body:free()
        self.actions = self:actionBar()
    end
    local visible = self.choices or self.model:visible()
    self.pages = math.max(1, math.ceil(#visible / self.per_page))
    self.page = math.max(1, math.min(self.page, self.pages))
    local list, focus_rows = VerticalGroup:new{ align = "left" }, {}
    local focus_y = 1
    for index = (self.page - 1) * self.per_page + 1, math.min(#visible, self.page * self.per_page) do
        local node = visible[index]
        local row, focus
        if self.choices then row, focus = self:choiceRow(node)
        else row, focus = self:chapterRow(node) end
        list[#list + 1], list[#list + 2] = row, self:line()
        focus_rows[#focus_rows + 1] = focus
        if node == focus_node or not focus_node and self.choices and node.current then focus_y = #focus_rows end
    end
    list[#list + 1] = VerticalSpan:new{ width = math.max(0, self.list_height - list:getSize().h) }
    -- getSize() caches offsets for the rows above. The appended spacer needs
    -- its own offset before the first paint (and after every page rebuild).
    list:resetLayout()
    local third = math.floor(self.width / 3)
    local previous = self:button(_("Previous"), third, function() self:onPrevPage() end,
        { enabled = self.page > 1, height = self.page_bar_height, text_font_size = 22, text_font_bold = true })
    local counter = self:button(T(_("%1/%2 pages"), tostring(self.page), tostring(self.pages)), third, nil,
        { enabled = false, height = self.page_bar_height, text_font_size = 18 })
    local next_page = self:button(_("Next"), self.width - third * 2, function() self:onNextPage() end,
        { enabled = self.page < self.pages, height = self.page_bar_height, text_font_size = 22, text_font_bold = true })
    focus_rows[#focus_rows + 1] = { self.action_button }
    focus_rows[#focus_rows + 1] = { previous, counter, next_page }
    self.layout = focus_rows
    self.body = VerticalGroup:new{ align = "left", list, self.actions, self:line(),
        HorizontalGroup:new{ previous, counter, next_page } }
    self[1] = FrameContainer:new{
        background = BB.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        VerticalGroup:new{ align = "left", self.title_bar, self.hint, self.body },
    }
    local column = focus_column or (self.choices and 1 or 2)
    FocusNav.initialFocus(self, math.min(column, #focus_rows[focus_y]), focus_y)
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
    self._closed = true
    UIManager:setDirty(nil, "ui")
end

local M = {}
function M.show(options)
    local picker = Picker:new(options)
    UIManager:show(picker)
    return picker
end
return M
