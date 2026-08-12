-- Focused test for context-sensitive actions in the WeRead quick menu.

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
    on_toggle_annotations = function() end,
    on_close_book = function() end,
}
Dialog.show({
    show_chapter_nav = true,
    show_next_chapter = true,
    enable_chapter_list = true,
    enable_next_chapter = false,
    enable_book_details = false,
    enable_sync_progress = true,
    annotations_visible = true,
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
expect(sync_row and #sync_row == 2,
    "sync and annotation visibility share the penultimate row")
expect(sync_row and sync_row[1].text == "Sync progress now",
    "the row starts with immediate progress sync")
expect(sync_row and sync_row[2].text == "Hide underlines and thoughts",
    "the row shows the current annotation toggle action")
expect(shown.buttons[1][1].text == "Chapter list"
        and shown.buttons[1][2].text == "Next chapter",
    "chapter actions stay visible in the global quick menu")
expect(shown.buttons[1][1].enabled == true
        and shown.buttons[1][2].enabled == false,
    "chapter actions reflect their individual availability")
expect(shown.buttons[2][1].enabled == false
        and sync_row[1].enabled == true,
    "book details and progress sync reflect their availability")

Dialog.show({
    enable_book_details = false,
    enable_sync_progress = false,
    annotations_visible = false,
}, callbacks)
sync_row = shown and shown.buttons[#shown.buttons - 1]
expect(#shown.buttons == 4,
    "shared action row remains visible without WeRead book context")
expect(sync_row and sync_row[1].enabled == false,
    "progress sync is disabled without WeRead book context")
expect(sync_row and sync_row[2].text == "Show underlines and thoughts",
    "hidden annotations expose the show action")

print(string.format(
    "end_of_book_dialog_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
