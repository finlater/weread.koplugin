-- KOREADER_WIDGET_DIR=/path/to/koreader luajit spec/koreader/annotation_picker_geometry.lua
-- Real KOReader Button and layout containers; inert fonts/screen/events.
dofile("spec/empty_state_face_spec.lua")
assert(os.getenv("KOREADER_WIDGET_DIR"))
local Device = require("device")
Device.hasDPad = function() return false end
local Size = require("ui/size")
Size.line = { medium = 1 }
Size.span = { vertical_default = 5 }
Size.padding.buttontable = 6
local FocusManager = require("ui/widget/focusmanager")
FocusManager.ges_events, FocusManager.selected = {}, { x = 1, y = 1 }
FocusManager.getSize = function(self) return self[1]:getSize() end
require("ui/widget/button").getSize = function(self) return self[1]:getSize() end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end,
        T = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
local Selection = require("weread.lib.chapter_selection")
local Picker = require("weread.ui.annotation_chapter_picker")
local chapters, toc, ranges = {}, {}, {}
for index = 1, 1000 do
    local uid = tostring(index)
    toc[index] = { title = "Local " .. uid, depth = index == 1 and 1 or 2, xpointer = uid }
    if index % 3 ~= 0 then
        chapters[#chapters + 1] = { chapterUid = uid, title = "Remote " .. uid }
        ranges[uid] = { toc_index = index }
    end
end
for _, size in ipairs({ { 600, 800 }, { 1072, 1448 }, { 800, 600 } }) do
    Device.screen.getWidth = function() return size[1] end
    Device.screen.getHeight = function() return size[2] end
    local model = Selection:new(chapters, ranges, toc, 1, function(chapter)
        return tonumber(chapter.chapterUid) % 2 == 0
            and "matched" or "ready_to_match"
    end)
    local chosen
    local view = Picker.show{ model = model, on_edit = function() end,
        on_select = function(result) chosen = result end }
    local function check()
        local bounds = view[1]:getSize()
        assert(bounds.w == size[1] and bounds.h == size[2], "native picker overflow")
        local list = view.body[1]
        for index = 1, #list - 1, 2 do
            local row = list[index]
            assert(row:getSize().h == view.row_height and row:getSize().w == size[1])
            assert(row[3]:getSize().h == view.row_height and row[4]:getSize().h == view.row_height,
                "status/secondary buttons exceeded row height")
        end
    end
    check()
    view.layout[1][1].callback()
    view:onNextPage(); check()
    view:onPrevPage(); check()
    assert(view.action_button.enabled and view.action_button:getSize().h == 64)
    assert(view.body[2] == view.actions and view.layout[#view.layout - 1][1] == view.action_button)
    view.action_button.callback()
    assert(chosen and #chosen == 1 and chosen[1] == chapters[1])
    print("Native annotation picker: " .. size[1] .. "x" .. size[2] .. "; " .. view.per_page .. " rows/page")
end
