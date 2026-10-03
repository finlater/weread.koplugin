-- Real KOReader updater UI, subprocess, persistence, and candidate installation.
-- Run with a fresh KO_HOME containing plugins/weread.koplugin and sibling fixtures/.
-- WEREAD_UPDATER_INTERACTIVE=1 leaves a native window for manual interaction.
require("setupkoenv")
local home = assert(os.getenv("KO_HOME"))
local root = assert(home:match("^(.*)/profile$"), "use an isolated test profile")
local interactive = os.getenv("WEREAD_UPDATER_INTERACTIVE") == "1"
if interactive then
    G_defaults = require("luadefaults"):open()
    G_reader_settings = require("luasettings"):open(home .. "/settings.reader.lua")
else
    package.path = "spec/front/unit/?.lua;" .. package.path
    require("commonrequire")
end
G_reader_settings:saveSetting("language", "zh_CN")
require("gettext").changeLang("zh_CN")
package.path = home .. "/plugins/weread.koplugin/?.lua;" .. package.path
local Device = require("device")
require("document/canvascontext"):init(Device)
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local json = require("json")
local Updater = require("weread.lib.updater")
local UpdaterUI = require("weread.ui.updater")
local Settings = require("weread.lib.settings")
local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end
local metadata = json.decode(read(root .. "/fixtures/release.json"))
local current_version = assert(read(home .. "/plugins/weread.koplugin/_meta.lua")
    :match('version%s*=%s*"([^"]+)"'))
local settings = Settings:new()
local state = settings:get("update")
state.prefer_proxy = false
settings:set("update", state)
settings:flush()
local core = Updater:new{
    settings = settings, current_version = current_version, plugin_dir = home .. "/plugins/weread.koplugin",
}
-- Inject only the HTTP boundary. Parsing, subprocesses, SHA-256 verification,
-- archive extraction, directory replacement, settings and all widgets stay real.
function core:_http_get(url, destination, progress, total)
    if url == Updater.API_URL then return json.encode(metadata) end
    local name = url:match("/([^/]+)$")
    assert(name == metadata.assets[1].name or name == metadata.assets[2].name, "unexpected fixture URL")
    local body = read(root .. "/fixtures/" .. name)
    local file = assert(io.open(destination, "wb"))
    for offset = 1, #body, 16384 do
        file:write(body:sub(offset, offset + 16383))
        if progress then progress(math.min(offset + 16383, #body), total) end
        ffiutil.usleep(10000)
    end
    file:close()
    return true
end
local ui = UpdaterUI:new{ updater = core, settings = settings }
local function top() return UIManager:getTopmostVisibleWidget() end
local function paint(name)
    UIManager:forceRePaint()
    Screen:shot(root .. "/evidence/" .. name .. ".png")
end
local function wait_for(predicate)
    local deadline = os.time() + 20
    UIManager:setRunForeverMode()
    UIManager:setInputTimeout(0)
    while not predicate() do
        assert(os.time() <= deadline, "updater smoke timed out")
        UIManager:handleInput()
        ffiutil.usleep(10000)
    end
    UIManager:forceRePaint()
end
local function check(manual)
    assert(ui:check(manual))
    wait_for(function() return not ui._checking end)
end
if interactive then
    local ButtonDialog = require("ui/widget/buttondialog")
    UIManager:show(require("ui/widget/container/framecontainer"):new{
        margin = 0, padding = 0, bordersize = 0,
        background = require("ffi/blitbuffer").COLOR_WHITE,
        require("ui/widget/rectspan"):new{ width = Screen:getWidth(), height = Screen:getHeight() },
    })
    UIManager:show(ButtonDialog:new{
        title = "更新提示测试 · 合成数据",
        buttons = {
            { { text = "自动检查", callback = function() ui:check(false) end } },
            { { text = "手动查看更新", callback = function() ui:show_cached_update() end } },
            { { text = "退出测试", callback = function() UIManager:quit() end } },
        },
    })
    UIManager:scheduleIn(1, function() ui:check(false) end)
    UIManager:run()
    os.exit(0)
end

check(false)
local viewer = assert(top())
assert(viewer.scroll_widget and viewer.scroll_widget.v_scroll_bar.enable, "long notes must scroll")
assert(viewer.text:find("最后一条更新", 1, true), "notes were truncated")
assert(#viewer.buttons_table == 2 and #viewer.buttons_table[1] == 2
    and #viewer.buttons_table[2] == 1, "unexpected navigation buttons")
paint("01-update")
for _, id in ipairs({ "later", "skip", "install" }) do
    local button = assert(viewer.button_table:getButtonById(id))
    local label = button.label_container[1]:getSize()
    assert(label.h <= button.label_container.dimen.h and label.w <= button.label_container.dimen.w,
        string.format("button label overflow: %s (%dx%d in %dx%d)", id, label.w, label.h,
            button.label_container.dimen.w, button.label_container.dimen.h))
    assert(button.dimen.y + button.dimen.h <= Screen:getHeight(), "button outside screen")
end
local button_y = viewer.button_table:getButtonById("install").dimen.y
viewer.scroll_widget:scrollToBottom()
paint("02-scrolled")
assert(viewer.scroll_widget.v_scroll_bar.low > 0, "scrollbar did not move")
assert(viewer.button_table:getButtonById("install").dimen.y == button_y, "buttons moved with notes")
viewer.button_table:getButtonById("later").callback()
assert(not core:should_notify(metadata.tag_name:sub(2)), "later did not snooze")
check(false)
assert(not top(), "snoozed release displayed again")
local persisted = Settings:new():get("update")
assert(persisted.snoozed_version == metadata.tag_name:sub(2) and persisted.snooze_until > os.time(),
    "snooze was not persisted to disk")
viewer = ui:show_cached_update()
assert(viewer, "manual entry did not bypass snooze")
viewer.button_table:getButtonById("skip").callback()
assert(Settings:new():get("update").skipped_version == metadata.tag_name:sub(2), "skip not persisted")
check(false)
assert(not top(), "skipped release displayed again")
check(true)
viewer = assert(top())
viewer:onClose()
assert(not top(), "native back/close left a viewer open")
local original_tag = metadata.tag_name
metadata.tag_name = "v9999.9.2"
metadata.assets = {
    { name = "weread.koplugin-v9999.9.2.zip", browser_download_url = Updater.RELEASE_PREFIX .. "v9999.9.2/test.zip" },
    { name = "weread.koplugin-v9999.9.2.zip.sha256", browser_download_url = Updater.RELEASE_PREFIX .. "v9999.9.2/test.sha256" },
}
check(false)
assert(top() and top().title:find("9999.9.2", 1, true), "newer release did not notify")
top():onClose()
metadata = json.decode(read(root .. "/fixtures/release.json"))
assert(metadata.tag_name == original_tag)
check(true)
viewer = assert(top())
local checksum_path = root .. "/fixtures/" .. metadata.assets[2].name
local checksum = read(checksum_path)
local broken = assert(io.open(checksum_path, "wb"))
broken:write(string.rep("0", 64)); broken:close()
viewer.button_table:getButtonById("install").callback()
wait_for(function() return top() and top().text and top().text:find("SHA-256", 1, true) end)
paint("03-checksum-failed")
assert(read(core.plugin_dir .. "/_meta.lua"):find('version = "' .. current_version .. '"', 1, true),
    "checksum failure replaced the candidate")
UIManager:close(top())
local restored = assert(io.open(checksum_path, "wb"))
restored:write(checksum); restored:close()
viewer = assert(ui:show_cached_update(), "failed install left updater locked")
viewer.button_table:getButtonById("install").callback()
wait_for(function() return top() and top().ok_text == "立即重启" end)
paint("04-installed")
assert(read(core.plugin_dir .. "/_meta.lua"):find('version = "9999.9.1"', 1, true), "candidate not replaced")
assert(read(core.plugin_dir .. ".backup/_meta.lua"):find('version = "' .. current_version .. '"', 1, true),
    "old candidate not preserved")
assert(not core:has_update(), "successful install left cached update active")
UIManager:close(top())
UIManager:quit()
print("PASS: native scrolling + fixed buttons + automatic/manual reminders + disk persistence + checksum rejection/retry + subprocess install")
