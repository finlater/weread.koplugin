-- Run from a built KOReader runtime with an isolated KO_HOME:
-- ./luajit /repo/spec/koreader/weread_about_smoke.lua /repo /evidence
-- Optional third argument: SimpleUI plugin directory, to exercise its real close hook.
-- Native layout, fonts, QR encoding and dismissal; no network or accounts.
-- luacheck: globals fastforward_ui_events
local repo, evidence = assert(arg[1]), assert(arg[2])
require("setupkoenv")
package.path = "spec/front/unit/?.lua;" .. repo .. "/?.lua;" .. package.path
require("commonrequire")
G_reader_settings:saveSetting("language", "zh_CN")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local BB = require("ffi/blitbuffer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Menu = require("weread.ui.menu")
local TouchMenu = require("ui/widget/touchmenu")
local QuickMenu = require("weread.ui.end_of_book_dialog")
local host = setmetatable({
    ui = {},
    version = "test",
    updater = { available_version = function() return nil end },
    settings = { get = function(_self, key, default)
        if key == "read_report" then return { mode = "auto" } end
        return default or {}
    end },
    safeCallback = function(_self, _label, callback) return callback end,
    detectWeReadBook = function() return "fixture-book" end,
    _xpointerOverlayPrototypeAvailable = function() return true end,
    _annotationBinding = function() return nil end,
}, { __index = Menu })
local Report = require("weread.ui.read_report")
local Annotations = require("weread.ui.annotation_sync_controller")
local simpleui, filemanager
local homescreen_returns = 0
if arg[3] then
    package.path = arg[3] .. "/?.lua;" .. package.path
    G_reader_settings:saveSetting("start_with", "homescreen_simpleui")
    filemanager = require("apps/filemanager/filemanager")
    -- Only the homepage renderer is a fixture; popup cleanup runs the actual SimpleUI hook.
    package.loaded["sui_homescreen"] = {
        show = function() homescreen_returns = homescreen_returns + 1 end,
    }
    simpleui = require("sui_patches")
end

local function top()
    return UIManager._window_stack[#UIManager._window_stack].widget
end

local function draw(name)
    fastforward_ui_events()
    Screen:shot(evidence .. "/" .. name .. ".png")
end

local function tap(widget)
    local rect = assert(widget.dimen)
    UIManager:sendEvent(Event:new("Gesture", {
        ges = "tap",
        pos = Geom:new{ x = rect.x + math.floor(rect.w / 2), y = rect.y + math.floor(rect.h / 2) },
    }))
    fastforward_ui_events()
end

local function findButton(button_table, text)
    for _, row in ipairs(button_table.buttons_layout) do
        for _, button in ipairs(row) do
            if button.text == text then return button end
        end
    end
    error("button not found: " .. text)
end

for _, size in ipairs({ { 600, 800 }, { 800, 600 }, { 1072, 1448 } }) do
    local width, height = size[1], size[2]
    Screen.bb:free()
    Screen.bb = BB.new(width, height)
    local background = WidgetContainer:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true,
        paintTo = function(_self, buffer) buffer:fill(BB.COLOR_WHITE) end,
    }
    if simpleui then
        filemanager.instance = background
        simpleui.patchUIManagerClose({ ui = background, _goalTapCallback = function() end })
    end
    UIManager:show(background)
    for _, mode in ipairs({ "filemanager", "reader", "about" }) do
        host.ui.document = mode == "reader" and { file = "/fixtures/book.epub" } or nil
        local items = mode == "about" and host:getAboutMenuItems() or host:getMainMenuItems()
        items.icon = "appbar.menu"
        local menu = TouchMenu:new{ width = width, tab_item_table = { items } }
        UIManager:show(menu)
        draw(mode .. "-menu-" .. width .. "x" .. height)
        assert(items[1].text == "升级到更完整的微信读书？")
        tap(menu.item_group[2])
        local introduction = top()
        assert(introduction.title == "weread闭源版(全平台搜 finlater)")
        tap(findButton(introduction.button_table, introduction.buttons_table[1][1].text))
        tap(top().title_bar.right_button)
        introduction = top()
        assert(introduction.title == "weread闭源版(全平台搜 finlater)", "QR dismissal should return to the menu's introduction")
        tap(findButton(introduction.button_table, introduction.buttons_table[3][1].text))
        assert(top() == menu, "introduction should return to its originating menu")
        menu:onClose()
    end
    host:showClosedSourceInfo()
    local viewer = top()
    draw("about-" .. width .. "x" .. height)
    assert(viewer.title == "weread闭源版(全平台搜 finlater)")
    assert(viewer.text:find("AI 问书", 1, true) and viewer.text:find("每周阅读奖励", 1, true))
    assert(viewer.text:find("获取安装包，请到闲鱼联系 finlater。", 1, true))
    local bold_runs, was_bold = 0, false
    local bold_chars = assert(viewer.box_widget._ptf_char_is_bold)
    for i, char in ipairs(require("util").splitToChars(viewer.box_widget.text)) do
        local bold = bold_chars[i] == true
        if bold and not was_bold then bold_runs = bold_runs + 1 end
        if char == "：" or char == ":" then assert(not bold, "only labels should be bold") end
        was_bold = bold
    end
    assert(bold_runs == 7, "all seven labels should render bold")
    assert(viewer.button_table.dimen.y >= 0)
    assert(viewer.button_table.dimen.y + viewer.button_table.dimen.h <= height,
        "recommendation buttons extend beyond the screen")
    viewer.scroll_widget:scrollToBottom()
    draw("about-bottom-" .. width .. "x" .. height)
    local return_line = viewer.box_widget.virtual_line_num
    local function returnedIntroduction()
        local returned = top()
        assert(returned.title == "weread闭源版(全平台搜 finlater)", "QR dismissal should return to the introduction")
        assert(returned.box_widget.virtual_line_num == return_line, "QR dismissal should preserve the scroll position")
        assert(#UIManager._window_stack == 2, "QR dismissal should leave only one introduction")
        return returned
    end
    for _, channel in ipairs({ {1, 1, "bilibili"}, {1, 2, "xiaohongshu"}, {2, 1, "xianyu"} }) do
        tap(findButton(viewer.button_table, viewer.buttons_table[channel[1]][channel[2]].text))
        local qr = top()
        assert(qr ~= viewer and qr.file:match("icons/" .. channel[3] .. "%.png$"))
        draw(channel[3] .. "-qr-" .. width .. "x" .. height)
        local frame = qr.dimen
        assert(frame.x >= 0 and frame.y >= 0
            and frame.x + frame.w <= width and frame.y + frame.h <= height)
        tap(qr.title_bar.right_button)
        viewer = returnedIntroduction()
        draw(channel[3] .. "-returned-" .. width .. "x" .. height)
        tap(findButton(viewer.button_table, viewer.buttons_table[channel[1]][channel[2]].text))
        qr = top()
        tap(qr)
        assert(qr.buttons_visible, "tapping the image should expose the close button")
        tap(qr.button_table:getButtonById("close"))
        viewer = returnedIntroduction()
        tap(findButton(viewer.button_table, viewer.buttons_table[channel[1]][channel[2]].text))
        UIManager:sendEvent(Event:new("Close"))
        fastforward_ui_events()
        viewer = returnedIntroduction()
    end
    tap(findButton(viewer.button_table, viewer.buttons_table[3][1].text))
    assert(top() == background, "return should close the introduction")

    local quick = QuickMenu.show({ show_chapter_nav = true, show_next_chapter = true })
    draw("quick-menu-" .. width .. "x" .. height)
    assert(quick.dimen.y >= 0 and quick.dimen.y + quick.dimen.h <= height,
        "quick menu extends beyond the screen")
    assert(#quick.buttons == 5, "quick menu should not include an edition guide")
    quick.buttons[#quick.buttons][1].callback()
    fastforward_ui_events()
    assert(top() == background)

    host.ui.document = { file = "/fixtures/book.epub" }
    local guides = host:getMainMenuItems()
    for _, item in ipairs(Report.getReadReportMenuItems(host)) do guides[#guides + 1] = item end
    for _, item in ipairs(Annotations.getUnifiedAnnotationMenuItems(host)) do guides[#guides + 1] = item end
    for _, item in ipairs(guides) do
        assert(not (item.text and item.text:find("（闭源版）", 1, true)),
            "separate feature promotions should be removed")
    end
    assert(top() == background)
    assert(homescreen_returns == 0, "QR dismissal must not trigger SimpleUI homepage restoration")
    UIManager:close(background)
    assert(#UIManager._window_stack == 0)
end
UIManager:quit()
print("PASS: menu navigation, QR title/bottom/back dismissal, scroll restoration and three screen sizes")
