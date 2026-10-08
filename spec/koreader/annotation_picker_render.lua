-- From a built KOReader runtime, with an isolated KO_HOME:
-- ./luajit /repo/spec/koreader/annotation_picker_render.lua /repo /evidence
-- Native fonts, layout, button feedback and framebuffer; no accounts/network.
-- luacheck: globals fastforward_ui_events
local repo, evidence = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = "spec/front/unit/?.lua;" .. repo .. "/?.lua;" .. package.path
require("commonrequire")
G_reader_settings:saveSetting("language", "zh_CN")
G_reader_settings:saveSetting("flash_ui", true)
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local BB = require("ffi/blitbuffer")
local Picker = require("weread.ui.annotation_chapter_picker")
local Selection = require("weread.lib.chapter_selection")
local Library = require("weread.ui.library_view")
local function draw(name)
    fastforward_ui_events()
    Screen:shot(evidence .. "/" .. name .. ".png")
end
local function tap(button)
    button:onTapSelectButton()
    fastforward_ui_events()
end
local toc, chapters, ranges = {}, {}, {}
local titles = { "第一章 人类的新议程", "第二章 人类世", "第三章 人类的特殊之处",
    "第四章 创造意义的故事：用于检查长章节标题和对应关系是否互相覆盖" }
for index = 1, 20 do
    local uid = tostring(index)
    local title = titles[index] or "第" .. index .. "章 示例章节"
    toc[index] = { title = title, xpointer = uid, depth = index == 4 and 2 or 1 }
    if index ~= 3 then
        chapters[#chapters + 1] = { chapterUid = uid, title = title }
        ranges[uid] = { toc_index = index }
    end
end
local model = Selection:new(chapters, ranges, toc, 2, function(chapter)
    return chapter.chapterUid == "1" and "matched" or "ready_to_fetch"
end)
model:toggle(model.nodes[2])
local selected
local picker = Picker.show{ model = model, book_title = "界面验证样书", on_edit = function() end,
    on_select = function(value) selected = value end }
draw("chapter-picker")
local function check_footer()
    local footer = picker.layout[#picker.layout]
    assert(picker.action_button.dimen.h == Screen:scaleBySize(64))
    assert(picker.action_button.dimen.y + picker.action_button.dimen.h <= footer[1].dimen.y)
    assert(footer[1].dimen.y + footer[1].dimen.h == Screen:getHeight())
end
check_footer()
tap(picker.layout[#picker.layout][3])
assert(picker.page == 2 and model.count == 1)
tap(picker.layout[#picker.layout][1])
assert(picker.page == 1)
tap(picker.layout[1][1])
assert(model.count == 2)
tap(picker.action_button)
assert(selected and #selected == 2 and picker._closed)

local choices, picked, removed = {}, nil, false
for index = 1, 20 do
    choices[index] = { text = toc[index].title,
        detail = index == 3 and "尚未对应本地章节" or "对应本地：" .. toc[index].title,
        select_enabled = index == 2 or index == 3, current = index == 2,
        status = index == 2 and "✓ 当前对应" or index == 3 and "可选择" or "已占用",
        callback = function() picked = index end }
end
local chooser = Picker.show{ choices = choices, local_title = toc[2].title,
    on_remove = function() removed = true end }
draw("chapter-chooser")
assert(chooser[1]:getSize().h == Screen:getHeight())
tap(chooser.layout[1][1]); assert(not picked, "occupied row accepted a tap")
tap(chooser.layout[3][1]); assert(picked == 3)
tap(chooser.layout[#chooser.layout][3]); assert(chooser.page == 2)
tap(chooser.layout[#chooser.layout][1]); assert(chooser.page == 1)
tap(chooser.action_button); assert(removed)
chooser:onClose()

for _, mode in ipairs({ "books", "public_account" }) do
    local shelf = Library.show({ mode = mode, books = {}, accounts = {}, groups = {} }, {})
    draw("shelf-" .. mode)
    local location, search = shelf._header_buttons[2], shelf._header_buttons[3]
    assert(location.dimen.x + location.dimen.w < search.dimen.x, "source feedback fills the blank space")
    local original_width = location.dimen.w
    location:_doFeedbackHighlight()
    UIManager:forceRePaint()
    Screen:shot(evidence .. "/shelf-" .. mode .. "-pressed.png")
    location:_undoFeedbackHighlight(false)
    assert(location.dimen.w == original_width)
    shelf:onClose()
end
-- Check the same real fonts/layout at a larger e-ink screen size.
Screen.bb:free()
Screen.bb = BB.new(1072, 1448)
picker = Picker.show{ model = model, book_title = "界面验证样书", on_select = function() end }
draw("chapter-picker-large")
check_footer()
picker:onClose()
UIManager:quit()
print("PASS: native chapter status/chooser, press feedback, pagination, action order and 600x800 / 1072x1448 rendering")
