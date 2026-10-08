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
        widget.height = (widget.height or scale(30)) + 2 * (widget.padding or 0) + 2 * (widget.bordersize or 0)
        assert(widget.width > 0 and widget.height > 0)
        live_buttons = live_buttons + 1; max_buttons = math.max(max_buttons, live_buttons)
        widget.label_widget = Widget:new{ kind = "text", max_width = widget.width }
        widget.label_container = Widget:new{ kind = "center", widget.label_widget }
        widget[1] = widget.label_container
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
    local padding = (self.padding or 0) + (self.bordersize or 0)
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
    ["textwidget"] = "text", ["titlebar"] = "title", ["container/centercontainer"] = "center",
    ["container/leftcontainer"] = "left",
}
for name, kind in pairs(kinds) do
    package.preload["ui/widget/" .. name] = function() return Widget:extend{ kind = kind } end
end
package.preload["ui/size"] = function()
    return { line = { medium = scale(1) }, padding = { buttontable = scale(6),
        large = scale(10), button = scale(5) }, span = { vertical_default = scale(5) } }
end
-- Optional device smoke test: use the installed KOReader layout groups, with
-- inert leaf widgets. No framebuffer, input device, settings or book is opened.
local group_root = os.getenv("KOREADER_GROUP_DIR")
if group_root then
    package.preload["ui/bidi"] = function() return { mirroredUILayout = function() return false end } end
    package.preload["util"] = function() return {} end
    package.preload["ui/widget/container/widgetcontainer"] = function() return Widget end
    for _, name in ipairs({ "verticalgroup", "horizontalgroup" }) do
        package.preload["ui/widget/" .. name] = function()
            return assert(loadfile(group_root .. "/ui/widget/" .. name .. ".lua"))()
        end
    end
end
package.preload["ui/geometry"] = function() return Widget end
package.preload["ui/gesturerange"] = function() return Widget end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = "black", COLOR_WHITE = "white",
        COLOR_DARK_GRAY = "dark_gray", COLOR_GRAY = "gray",
        COLOR_GRAY_E = "gray_e", COLOR_LIGHT_GRAY = "light_gray" }
end
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
    return { tr = function(s) return s end, T = function(s, ...) local values = {...}
        return (s:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end)) end }
end
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, callback) callback() end,
        setDirty = function(_, widget) if widget and widget[1] then widget[1]:paintTo({}, 0, 0) end end,
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
    view.layout[1][1].callback() -- parent selects only its own chapter
    view.layout[2][1].callback()
    assert(model.count == 2 and #model:visible() == 2000)
    assert(view.action_button:getSize().h == scale(64), "fetch target is too small")
    assert(view.body[2] == view.actions and view.layout[#view.layout - 1][1] == view.action_button,
        "fetch action must precede the bottom pagination in paint and keyboard order")
    assert(view.layout[#view.layout][1].text == "Previous" and view.layout[#view.layout][3].text == "Next")
    view.action_button.callback()
    assert(chosen and #chosen == 2 and chosen[1] == chapters[1] and chosen[2] == chapters[2])
    assert(live_buttons == 0, "closing picker retained native widget resources")
end
-- Linked rows distinguish network fetches from local matching, while completed
-- rows use the emphasized matched badge.
width, height = 600, 800
local state_chapters = {
    { chapterUid = "fetch", title = "Fetch" },
    { chapterUid = "match", title = "Match" },
    { chapterUid = "done", title = "Done" },
}
local state_model = Selection:new(state_chapters, {}, nil, 1, function(chapter)
    return chapter.chapterUid == "fetch" and "ready_to_fetch"
        or chapter.chapterUid == "match" and "ready_to_match" or "matched"
end)
local state_view = Picker.show{ model = state_model, on_select = function() end }
local function badge(row_index)
    local row = state_view.body[1][row_index * 2 - 1]
    local center = row[4][1]
    local frame = center[1]
    return center, frame, frame[1]
end
local fetch_center, fetch_frame, fetch_text = badge(1)
local match_center, match_frame, match_text = badge(2)
local done_center, done_frame, done_text = badge(3)
assert(fetch_text.text == "Ready to fetch" and match_text.text == "Ready to match"
    and done_text.text == "✓ Matched", "chapter state badges use the wrong labels")
assert(fetch_center.dimen.w == scale(92) and match_center.dimen.w == scale(92)
    and done_center.dimen.w == scale(92), "chapter state badge width changed")
assert(fetch_frame.bordersize == state_view.line_height
    and match_frame.bordersize == state_view.line_height
    and fetch_frame.background == "white" and match_frame.background == "white"
    and done_frame.bordersize == 0 and done_frame.background == "black"
    and done_text.fgcolor == "white" and done_text.bold,
    "chapter state badge styling does not distinguish matched rows")
state_view:onClose(); assert(live_buttons == 0)
-- Editing rebuilds the current page and preserves other selected rows. A
-- completed row remains selectable; an unmatched row only permits editing.
width, height = 600, 800
local targets, toc, ranges = {}, {}, {}
for index = 1, 30 do
    toc[index] = { title = "Local " .. index, xpointer = tostring(index) }
    if index > 1 then
        targets[#targets + 1] = { chapterUid = tostring(index), title = "Remote " .. index }
        ranges[tostring(index)] = { toc_index = index }
    end
end
local model = Selection:new(targets, ranges, toc, 20, function() return "matched" end)
local view = Picker.show{ model = model, on_select = function() end, on_edit = function(node, rebuild)
    ranges[tostring(node.index)] = nil
    local remaining = {}
    for _, chapter in ipairs(targets) do
        if chapter.chapterUid ~= tostring(node.index) then remaining[#remaining + 1] = chapter end
    end
    rebuild(Selection:new(remaining, ranges, toc))
end }
local page = view.page
view.layout[1][1].callback(); view.layout[2][1].callback()
assert(model.count == 2, "retrieved rows cannot be selected again")
view.layout[2][3].callback()
assert(view.page == page and view.model.count == 1 and not view.layout[2][1].enabled,
    "editing lost the page/other selections or retained an unmatched selection")
view:onClose(); assert(live_buttons == 0)
-- The chooser uses one two-line button per visible candidate and starts on
-- the current match. Occupied entries never become selectable.
local choices = {}
for index = 1, 1000 do
    choices[index] = { text = "Remote " .. index, detail = "Local: Chapter " .. index,
        status = "Already linked", select_enabled = false, current = index == 20 }
end
choices[20].select_enabled = true
local saved, removed
choices[20].callback = function() saved = 20 end
view = Picker.show{ choices = choices, local_title = "Current local chapter",
    on_remove = function() removed = true end }
assert(view.page == math.ceil(20 / view.per_page))
assert(view[1]:getSize().h == height and live_buttons == math.min(view.per_page, #choices) + 4)
local chosen_row = view.layout[(20 - 1) % view.per_page + 1][1]
assert(chosen_row.enabled and not view.layout[1][1].enabled)
chosen_row.callback(); assert(saved == 20)
local initial = live_buttons
view:onNextPage(); view:onPrevPage()
assert(live_buttons == initial, "chooser kept old page widgets")
view.action_button.callback(); assert(removed)
view:onClose(); assert(live_buttons == 0)
print("annotation_chapter_picker_spec: independent selection, editing, geometry and bounded widgets passed; peak=" .. max_buttons)
