-- Reading-report target picker reuses the bookshelf in books-only mode.

package.path = "./?.lua;./?/init.lua;" .. package.path

local closed_view
package.preload["ui/uimanager"] = function()
    return { close = function(_self, view) closed_view = view end }
end
package.preload["weread.lib.logger"] = function()
    return { err = function() end }
end
package.preload["weread.lib.read_stats"] = function() return {} end
package.preload["weread.ui.read_stats_view"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(args[tonumber(index)])
            end))
        end,
        log_error = tostring,
        display_error = tostring,
    }
end

local ReadReportUI = require("weread.ui.read_report")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local config = { mode = "auto", book_id = "", book_title = "" }
local picker_options
local stopped, started, notice
local host = setmetatable({
    settings = {
        get = function(_self, key)
            if key == "read_report" then return config end
        end,
        set = function(_self, key, value)
            if key == "read_report" then config = value end
        end,
        flush = function() end,
    },
    requireLogin = function() return true end,
    refreshBookshelf = function(_self, _view, options) picker_options = options end,
    stopReadReport = function(_self, reason) stopped = reason end,
    maybeStartReadReport = function() started = true end,
    showTransientInfo = function(_self, text) notice = text end,
    safeCallback = function(_self, _label, callback) return callback end,
}, { __index = ReadReportUI })

local report_items = host:getReadReportMenuItems()
expect(report_items[1].keep_menu_open == true
        and report_items[2].keep_menu_open == true
        and report_items[4].keep_menu_open == true,
    "reading report actions keep their menu open")
local target_items = host:getReportTargetMenuItems()
expect(target_items[1].keep_menu_open == true
        and target_items[2].keep_menu_open == true,
    "report target actions keep their menu open")

local menu_refreshes = 0
local touchmenu = {
    updateItems = function()
        menu_refreshes = menu_refreshes + 1
    end,
}
report_items[1].callback(touchmenu)
report_items[2].callback(touchmenu)
target_items[1].callback(touchmenu)
target_items[2].callback(touchmenu)
expect(menu_refreshes == 4,
    "reading report toggles did not refresh the open menu")

host:showReadReportBookPicker()
expect(picker_options and picker_options.mode == "books",
    "report picker did not open on the books tab")
expect(picker_options.wp_enable == false,
    "report picker did not disable the public-accounts tab")

picker_options.on_select(
    { bookId = "mp_1", title = "Account" }, "public_account", {}
)
expect(config.book_id == "", "disabled public-account selection changed the target")

local view = {}
host.shelf_view = view
picker_options.on_select({ bookId = "book_1", title = "Book One" }, "books", view)
expect(config.mode == "manual" and config.book_id == "book_1"
        and config.book_title == "Book One",
    "book selection did not save the manual report target")
expect(closed_view == view and host.shelf_view == nil,
    "book selection did not close and release the picker view")
expect(stopped == "target_changed" and started == true
        and notice == "Target book set: Book One",
    "book selection did not restart reporting with feedback")

local status_text
local report_status = { running = false, count = 0 }
host.read_report = { status = function() return report_status end }
host.showInfo = function(_self, text) status_text = text end
expect(host:onShowWeReadReportStatus(), "status gesture consumes the reader event")
expect(status_text == "Report book: Book One\nStatus: Stopped\nReported: 0 times, last: --",
    "status gesture displays the manual target before the first report")
local gesture_text = status_text
status_text = nil
report_items[4].callback()
expect(status_text == gesture_text, "menu and gesture show the same report status")

config.mode = "auto"
report_status = {
    running = true, count = 3, target_book_title = "Auto Book",
    last_time = 12345, last_error = "offline",
}
host:onShowWeReadReportStatus()
expect(status_text == "Report book: Auto: Auto Book\nStatus: Running\nReported: 3 times, last: "
        .. os.date("%H:%M:%S", report_status.last_time) .. "\nLast error: offline",
    "status gesture preserves the live automatic target, report time, and last error")

print(("read_report_picker_spec: %d checks"):format(checks))
