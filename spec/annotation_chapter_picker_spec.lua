-- UI geometry, page allocation and callbacks with small native-widget fakes.
-- This does not replace visual verification on KOReader/e-ink hardware.
package.path = "./?.lua;" .. package.path
local width, height, live_buttons, max_buttons = 600, 800, 0, 0
local function scale(n) return math.floor(n * width / 600) end
local Widget = {}
function Widget:extend(args) return setmetatable(args or {}, { __index = self }) end
function Widget:new(args)
    local widget = self:extend(args)
    widget.key_events, widget.ges_events, widget.selected = {}, {}, { x = 1, y = 1 }
    if widget.kind == "button" then
        widget.height = widget.height or scale(30) + 2 * (widget.padding or 0)
        assert(widget.width > 0 and widget.height > 0)
        live_buttons = live_buttons + 1; max_buttons = math.max(max_buttons, live_buttons)
    end
    if widget.init then widget:init() end
    return widget
end
function Widget:getSize()
    if self.kind == "button" then return { w = self.width, h = self.height } end
    if self.kind == "title" then return { w = self.width, h = scale(80) } end
    if self.kind == "text" then return { w = self.max_width, h = scale(20) } end
    if self.kind == "hspan" then return { w = self.width, h = 0 } end
    if self.kind == "vspan" then return { w = 0, h = self.width } end
    if self.dimen then return self.dimen end
    local group = self.kind == "horizontal" or self.kind == "vertical"
    if group and self._size then return self._size end
    if group then self._offsets = {} end
    local w, h = 0, 0
    for index, child in ipairs(self) do
        local size = child:getSize()
        if group then self._offsets[index] = { x = w, y = h } end
        if self.kind == "horizontal" then w, h = w + size.w, math.max(h, size.h)
        elseif self.kind == "vertical" then w, h = math.max(w, size.w), h + size.h
        else w, h = math.max(w, size.w), math.max(h, size.h) end
    end
    local padding = self.padding or 0
    local size = { w = w + 2 * padding, h = h + 2 * padding }
    if group then self._size = size end
    return size
end
function Widget:resetLayout() self._size, self._offsets = nil, {} end
function Widget:paintTo(bb, x, y)
    self:getSize()
    for index, child in ipairs(self) do
        if self.kind == "horizontal" or self.kind == "vertical" then
            assert(self._offsets[index], "layout cache has no position for an appended widget")
        end
        child:paintTo(bb, x, y)
    end
end
function Widget:getHeight() return self:getSize().h end
function Widget:free()
    assert(not self.freed, "page widget freed twice")
    self.freed = true
    if self.kind == "button" then live_buttons = live_buttons - 1 end
    for _, child in ipairs(self) do child:free() end
end
local kinds = {
    ["button"] = "button", ["focusmanager"] = "focus", ["container/framecontainer"] = "frame",
    ["horizontalgroup"] = "horizontal", ["verticalgroup"] = "vertical",
    ["horizontalspan"] = "hspan", ["verticalspan"] = "vspan", ["linewidget"] = "line",
    ["textwidget"] = "text", ["titlebar"] = "title",
}
for name, kind in pairs(kinds) do
    package.preload["ui/widget/" .. name] = function() return Widget:extend{ kind = kind } end
end
package.preload["ui/size"] = function()
    return { line = { medium = scale(1) }, padding = { buttontable = scale(6),
        large = scale(10), button = scale(5) }, span = { vertical_default = scale(5) } }
end
package.preload["ui/widget/buttontable"] = function()
    local Bar = Widget:extend{}
    function Bar:init()
        local Button = require("ui/widget/button")
        local Horizontal = require("ui/widget/horizontalgroup")
        local Vertical = require("ui/widget/verticalgroup")
        local Span = require("ui/widget/verticalspan")
        local Line = require("ui/widget/linewidget")
        local sep = scale(1)
        local row = Horizontal:new{}
        self.buttons_layout = { {} }
        for index, entry in ipairs(self.buttons[1]) do
            local button = Button:new{ text = entry.text, callback = entry.callback, enabled = entry.enabled,
                width = math.floor((self.width - sep) / 2), padding = scale(6) }
            row[#row + 1] = button
            self.buttons_layout[1][index] = button
            if index == 1 then row[#row + 1] = Line:new{ dimen = { w = sep, h = button:getSize().h } } end
        end
        self[1] = Vertical:new{ Line:new{ dimen = { w = self.width, h = sep } },
            Span:new{ width = scale(5) }, row, Span:new{ width = scale(5) } }
    end
    return Bar
end
-- Optional device smoke test: use the installed KOReader layout groups, with
-- inert leaf widgets. No framebuffer, input device, settings or book is opened.
local group_root = os.getenv("KOREADER_GROUP_DIR")
if group_root then
    package.preload["ui/bidi"] = function() return { mirroredUILayout = function() return false end } end
    package.preload["util"] = function() return {} end
    package.preload["ui/widget/container/widgetcontainer"] = function() return Widget end
    for _, name in ipairs({ "verticalgroup", "horizontalgroup", "buttontable" }) do
        package.preload["ui/widget/" .. name] = function()
            return assert(loadfile(group_root .. "/ui/widget/" .. name .. ".lua"))()
        end
    end
end
package.preload["ui/geometry"] = function() return Widget end
package.preload["ui/gesturerange"] = function() return Widget end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ffi/blitbuffer"] = function() return {} end
package.preload["device"] = function()
    return { screen = { getWidth = function() return width end, getHeight = function() return height end,
        scaleBySize = function(_, n) return scale(n) end }, hasKeys = function() return true end,
        hasDPad = function() return false end,
        input = { group = { Back = "Back", PgFwd = "Next", PgBack = "Prev" } } }
end
package.preload["weread.ui.focus_nav"] = function()
    return { initialFocus = function(self, x, y)
        assert(self.layout[y] and self.layout[y][x], "invalid focus after page rebuild")
        self.selected = { x = x, y = y }
    end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s, n) return (s:gsub("%%1", tostring(n))) end }
end
package.preload["ui/uimanager"] = function()
    return { setDirty = function(_, widget) if widget and widget[1] then widget[1]:paintTo({}, 0, 0) end end,
        show = function(_, widget) widget[1]:paintTo({}, 0, 0) end,
        close = function(_, widget) widget[1]:free(); widget:onCloseWidget() end }
end
local Selection = require("weread.lib.chapter_selection")
local Picker = require("weread.ui.annotation_chapter_picker")
for _, size in ipairs({ { 600, 800 }, { 1072, 1448 }, { 800, 600 } }) do
    width, height = size[1], size[2]
    local chapters = {}
    for index = 1, 2000 do
        chapters[index] = { chapterUid = tostring(index), title = "Chapter " .. index,
            level = index == 1 and 1 or 2 }
    end
    local model = Selection:new(chapters, {}, nil, 20)
    local chosen
    local view = Picker.show{
        model = model, book_title = "Fixture",
        on_select = function(result) chosen = result end,
    }
    assert(view.page == math.ceil(20 / view.per_page), "current chapter opened on the wrong page")
    local bounds = view[1]:getSize()
    assert(bounds.w == width and bounds.h == height, "picker layout overflows or fails to fill the screen")
    assert(live_buttons <= 4 * view.per_page + 5, "hidden catalog rows allocated widgets")
    local initial = live_buttons
    for _ = 1, 30 do
        view.layout[1][2].callback() -- toggle a chapter
        view:onNextPage(); view:onPrevPage()
    end
    assert(live_buttons == initial, "page changes retained old widgets")
    assert(model.count == 0, "repeated toggling lost selection state")
    while view.page > 1 do view:onPrevPage() end
    view.layout[1][3].callback() -- parent checkbox
    assert(model.count == 2000)
    view.layout[1][1].callback() -- collapse root
    assert(view.pages == 1 and #model:visible() == 1 and model.count == 2000)
    assert(live_buttons == 8, "collapsed subtree retained page widgets")
    assert(view.actions.zero_sep and #view.actions.buttons_layout[1] == 2,
        "picker does not use the native separated action bar")
    view.layout[#view.layout][2].callback() -- fixed bottom match action
    assert(chosen and #chosen == 2000 and chosen[1] == chapters[1])
    assert(live_buttons == 0, "closing picker retained native widget resources")
end
-- Completed rows lose their checkbox; a mixed parent still selects the other
-- children. A fully matched book keeps both bottom actions disabled.
local targets = { { chapterUid = "p", level = 1 }, { chapterUid = "done", level = 2 },
    { chapterUid = "todo", level = 2 } }
local mixed = Selection:new(targets, {}, nil, 2, function(chapter) return chapter.chapterUid ~= "todo" end)
local view = Picker.show{ model = mixed, on_select = function() end }
assert(not view.layout[2][2].enabled and not view.layout[2][3].enabled
    and view.layout[2][3].text == "", "completed row retained an active checkbox")
view.layout[2][3].callback(); assert(mixed.count == 0)
view.layout[1][3].callback(); assert(mixed.count == 1 and #mixed:selection() == 1)
assert(view.actions.buttons_layout[1][2].text == "Match (1)")
view:onClose(); assert(live_buttons == 0)
local complete = Selection:new(targets, {}, nil, 2, function() return true end)
view = Picker.show{ model = complete, on_select = function() error("completed book submitted") end }
assert(not view.layout[1][3].enabled and not view.actions.buttons_layout[1][1].enabled
    and not view.actions.buttons_layout[1][2].enabled)
view:onClose(); assert(live_buttons == 0)
print("annotation_chapter_picker_spec: pagination, parent callbacks, geometry and bounded widgets passed; peak=" .. max_buttons)
