-- Focused test for the full-width sync row in the WeRead quick menu.

package.path = "./?.lua;" .. package.path

local shown
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_self, options) return options end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, dialog) shown = dialog end,
        close = function() end,
        scheduleIn = function(_self, _delay, callback) callback() end,
    }
end
package.preload["weread.lib.i18n"] = function()
    return { tr = function(text) return text end }
end

local Dialog = require("weread.ui.end_of_book_dialog")

local callbacks = {
    on_bookshelf = function() end,
    on_search = function() end,
    on_book_details = function() end,
    on_read_stats = function() end,
    on_sync_progress = function() end,
    on_close_book = function() end,
}
Dialog.show({
    show_chapter_nav = true,
    show_next_chapter = true,
    show_sync_progress = true,
}, callbacks)

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

expect(shown and shown.title == "WeRead · Quick menu",
    "quick menu keeps the requested title")
local sync_row = shown and shown.buttons[#shown.buttons - 1]
expect(sync_row and #sync_row == 1,
    "sync progress is a full-width penultimate row")
expect(sync_row and sync_row[1].text == "Sync progress now",
    "penultimate row is the immediate sync action")
expect(shown.buttons[1][1].text == "Chapter list"
        and shown.buttons[1][2].text == "Next chapter",
    "chapter actions stay visible in the global quick menu")

Dialog.show({ show_sync_progress = false }, callbacks)
expect(#shown.buttons == 3,
    "sync row is omitted when the current document is not a WeRead book")

print(string.format(
    "end_of_book_dialog_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
