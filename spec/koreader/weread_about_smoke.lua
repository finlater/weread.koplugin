-- Run from a built KOReader runtime with an isolated KO_HOME:
-- ./luajit /repo/spec/koreader/weread_about_smoke.lua /repo /evidence
-- Native layout, fonts, QR encoding and dismissal; no network or accounts.
-- luacheck: globals fastforward_ui_events
local repo, evidence = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = "spec/front/unit/?.lua;" .. repo .. "/?.lua;" .. package.path
require("commonrequire")
G_reader_settings:saveSetting("language", "zh_CN")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local BB = require("ffi/blitbuffer")
local Menu = require("weread.ui.menu")

local function top()
    return UIManager._window_stack[#UIManager._window_stack].widget
end

local function draw(name)
    fastforward_ui_events()
    Screen:shot(evidence .. "/" .. name .. ".png")
end

for _, size in ipairs({ { 600, 800 }, { 800, 600 }, { 1072, 1448 } }) do
    local width, height = size[1], size[2]
    Screen.bb:free()
    Screen.bb = BB.new(width, height)
    Menu.showWeReaderInfo({})
    local viewer = top()
    draw("about-" .. width .. "x" .. height)
    assert(viewer.title == "WeReader 闭源版")
    assert(viewer.text:find("小红书/闲鱼昵称：finlater", 1, true))
    assert(viewer.button_table.dimen.y >= 0)
    assert(viewer.button_table.dimen.y + viewer.button_table.dimen.h <= height,
        "recommendation buttons extend beyond the screen")
    viewer.buttons_table[1][1].callback()
    local qr = top()
    assert(qr ~= viewer and qr.text == "http://xhslink.com/m/8aP668RQREF")
    draw("xiaohongshu-qr-" .. width .. "x" .. height)
    local frame = qr[1][1].dimen
    assert(frame.x >= 0 and frame.y >= 0
        and frame.x + frame.w <= width and frame.y + frame.h <= height)
    qr:onTapClose()
    fastforward_ui_events()
    assert(top() == viewer, "QR dismissal should return to the introduction")
    viewer.buttons_table[2][1].callback()
    fastforward_ui_events()
    assert(#UIManager._window_stack == 0, "return should close the introduction")
end
UIManager:quit()
print("PASS: native recommendation, QR generation, return flow and three screen sizes")
